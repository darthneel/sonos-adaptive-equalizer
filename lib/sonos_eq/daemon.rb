# frozen_string_literal: true

require "time"
require "rexml/document"
require_relative "config"
require_relative "discovery"
require_relative "soap_client"
require_relative "genre_classifier"
require_relative "genre_enricher"
require_relative "genre_normalizer"
require_relative "eq_policy"
require_relative "store"

module SonosEq
  class Daemon
    AV_TRANSPORT = "urn:schemas-upnp-org:service:AVTransport:1"
    RENDERING_CONTROL = "urn:schemas-upnp-org:service:RenderingControl:1"

    def initialize(config_path, once: false, dry_run: false)
      @config_path = File.expand_path(config_path)
      @dry_run = dry_run
      @once = once || dry_run
      @soap = SoapClient.new
      @last_track_key = {}
      @last_track_ctx = {}
      @last_applied = {}
      @last_apply_at = {}
      @override_candidates = {}
      @config = nil
      @policy = nil
      @store = nil
    end

    def run
      cfg = load_config
      @config = cfg
      db_path = db_path_from_config(cfg)
      if @dry_run && File.exist?(db_path)
        @store = Store.new(db_path: db_path, readonly: true)
      else
        @store = Store.new(db_path: @dry_run ? ":memory:" : db_path)
        @store.setup!
        @store.import_legacy!(config: cfg, config_dir: File.dirname(@config_path))
      end
      discovery = Discovery.new(timeout_sec: cfg.dig("network", "discovery_timeout_sec").to_i)
      devices = discovery.discover
      raise "No Sonos devices discovered" if devices.empty?
      sync_devices_registry!(devices, cfg) unless @dry_run

      monitored = select_monitored_devices(devices, cfg)
      raise "No matching Sonos devices found for targeting rules" if monitored.empty?

      genre_presets = @store.load_genre_presets
      normalizer = GenreNormalizer.new(genre_presets)
      classifier = GenreClassifier.new(normalizer)
      genre_enricher = GenreEnricher.new(
        config: cfg["genre_lookup"] || {},
        store: @store,
        normalizer: normalizer,
        cache_writes: !@dry_run
      )
      overrides = @store.load_overrides
      @policy = EqPolicy.new(@store.load_default_settings || {}, genre_presets, overrides)

      puts "Discovered rooms: #{devices.map(&:room_name).sort.join(', ')}"
      puts "Monitoring rooms: #{monitored.map(&:room_name).sort.join(', ')}"
      puts "Dry run: speaker and persistent-state writes are disabled" if @dry_run
      last_discovery_at = monotonic_now

      loop do
        monitored.each do |device|
          process_device(device, classifier, genre_enricher, @policy, cfg)
        end
        break if @once

        sleep cfg.dig("network", "poll_interval_sec").to_i
        rediscovery_interval = cfg.dig("network", "rediscovery_interval_sec").to_f
        if monotonic_now - last_discovery_at >= rediscovery_interval
          monitored = rediscover_monitored_devices(discovery, monitored, cfg)
          last_discovery_at = monotonic_now
        end
      end
    end

    private

    def load_config
      Config.load(@config_path)
    end

    def process_device(device, classifier, genre_enricher, policy, cfg)
      track_info = current_track_info(device)
      return if track_info.nil?

      track_key = track_key_for(track_info)
      playback = playback_context(track_info)

      if @last_track_key[device.udn] && @last_track_key[device.udn] != track_key
        finalize_override_candidate(device.udn, discard_if_unstable: true)
      end
      @last_track_key[device.udn] = track_key

      unless playback[:manageable]
        puts "#{timestamp} room=#{device.room_name} skip=unmanaged_playback source_type=#{playback[:source_type].inspect} has_identity=#{playback[:has_identity]}"
        return
      end

      local_genre = classifier.detect(track_info)
      genre = local_genre
      genre_source = "local"
      if genre == "unknown"
        resolved = genre_enricher.resolve(track_info)
        unless resolved[:genre].to_s.strip.empty?
          genre = classifier.canonicalize(resolved[:genre])
          genre_source = "lookup:#{resolved[:source]}"
        end
      end
      include_ht_music = ht_music_enabled_for_room?(device.room_name, cfg) && playback[:music_source]
      current_eq = current_eq(device, include_ht_music: include_ht_music)
      current_ctx = {
        device_id: device.udn,
        room_name: device.room_name,
        title: track_info[:title].to_s,
        artist: track_info[:artist].to_s,
        genre: genre,
        track_key: track_key,
        source_type: playback[:source_type]
      }
      @last_track_ctx[device.udn] = current_ctx

      resolved = policy.resolve(
        device_id: device.udn,
        room_name: device.room_name,
        title: track_info[:title],
        artist: track_info[:artist],
        genre: genre
      )
      target_preset = resolved.preset

      puts "#{timestamp} room=#{device.room_name} title=#{track_info[:title].inspect} artist=#{track_info[:artist].inspect} genre=#{genre.inspect} genre_source=#{genre_source.inspect} source=#{resolved.source.inspect}"
      @last_applied[device.udn] ||= current_eq.dup

      if manual_override_detected?(device.udn, current_eq)
        observe_override_candidate(device.udn, current_ctx, current_eq, cfg)
        finalize_override_candidate(device.udn)
        return
      end
      finalize_override_candidate(device.udn)

      cooldown = cfg.dig("network", "apply_cooldown_sec").to_i
      if eq_matches_target?(current_eq, target_preset)
        return
      end

      if cooldown_active?(device.udn, cooldown)
        puts "#{timestamp} room=#{device.room_name} skip=cooldown"
      elsif @dry_run
        puts "#{timestamp} room=#{device.room_name} would_apply=#{target_preset}"
      else
        apply_eq(device, target_preset, current_eq: current_eq, include_ht_music: include_ht_music)
        @last_applied[device.udn] = merge_preset_onto_current(current_eq, target_preset)
        @last_apply_at[device.udn] = Time.now
        puts "#{timestamp} room=#{device.room_name} applied=#{target_preset}"
      end
    rescue StandardError => e
      puts "#{timestamp} room=#{device.room_name} error=#{e.message.inspect}"
    end

    def current_track_info(device)
      response = @soap.call(
        control_url: device.av_transport_control_url,
        service_type: AV_TRANSPORT,
        action: "GetPositionInfo",
        arguments: { "InstanceID" => 0, "Channel" => "Master" }
      )

      track_uri = response["TrackURI"].to_s
      track_metadata_xml = response["TrackMetaData"].to_s
      didl = parse_didl(track_metadata_xml)

      {
        track_uri: track_uri,
        track_metadata_xml: track_metadata_xml,
        title: didl[:title].to_s,
        artist: didl[:artist].to_s,
        album: didl[:album].to_s
      }
    end

    def current_eq(device, include_ht_music:)
      bass_response = @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: "GetBass",
        arguments: { "InstanceID" => 0, "Channel" => "Master" }
      )
      treble_response = @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: "GetTreble",
        arguments: { "InstanceID" => 0, "Channel" => "Master" }
      )
      loudness_response = @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: "GetLoudness",
        arguments: { "InstanceID" => 0, "Channel" => "Master" }
      )

      out = {
        "bass" => bass_response.fetch("CurrentBass", "0").to_i,
        "treble" => treble_response.fetch("CurrentTreble", "0").to_i,
        "loudness" => loudness_response.fetch("CurrentLoudness", "1").to_i == 1
      }

      if include_ht_music
        out["sub_gain"] = get_eq_value(device, "SubGain")
        out["surround_level"] = get_eq_value(device, "SurroundLevel")
      end

      out
    end

    def parse_didl(xml)
      return {} if xml.nil? || xml.empty? || xml == "NOT_IMPLEMENTED"

      doc = REXML::Document.new(xml)
      {
        title: text_for_local_name(doc, "title"),
        artist: text_for_local_name(doc, "creator"),
        album: text_for_local_name(doc, "album")
      }
    rescue StandardError
      {}
    end

    def text_for_local_name(doc, local_name)
      REXML::XPath.first(doc, "//*[local-name()='#{local_name}']")&.text.to_s.strip
    end

    def apply_eq(device, preset, current_eq:, include_ht_music:)
      apply_rendering_value(device, current_eq, preset, "bass", "SetBass", "DesiredBass")
      apply_rendering_value(device, current_eq, preset, "treble", "SetTreble", "DesiredTreble")
      apply_rendering_value(device, current_eq, preset, "loudness", "SetLoudness", "DesiredLoudness") do |value|
        value ? 1 : 0
      end
      if include_ht_music
        apply_eq_value(device, current_eq, preset, "sub_gain", "SubGain")
        apply_eq_value(device, current_eq, preset, "surround_level", "SurroundLevel")
      end
    end

    def apply_rendering_value(device, current_eq, preset, key, action, argument)
      return unless preset.key?(key)
      return if normalize_eq_value(key, current_eq[key]) == normalize_eq_value(key, preset[key])

      value = block_given? ? yield(preset[key]) : preset[key]
      set_rendering(device, action, argument, value)
      remember_daemon_write(device.udn, key, preset[key])
    end

    def apply_eq_value(device, current_eq, preset, key, eq_type)
      return unless preset.key?(key)
      return if normalize_eq_value(key, current_eq[key]) == normalize_eq_value(key, preset[key])

      set_eq_value(device, eq_type, preset[key])
      remember_daemon_write(device.udn, key, preset[key])
    end

    def remember_daemon_write(udn, key, value)
      @last_applied[udn] ||= {}
      @last_applied[udn][key] = value
    end

    def set_rendering(device, action, arg_name, value)
      @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: action,
        arguments: {
          "InstanceID" => 0,
          "Channel" => "Master",
          arg_name => value
        }
      )
    end

    def get_eq_value(device, eq_type)
      response = @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: "GetEQ",
        arguments: {
          "InstanceID" => 0,
          "EQType" => eq_type
        }
      )
      response.fetch("CurrentValue", "0").to_i
    rescue StandardError
      nil
    end

    def set_eq_value(device, eq_type, value)
      @soap.call(
        control_url: device.rendering_control_url,
        service_type: RENDERING_CONTROL,
        action: "SetEQ",
        arguments: {
          "InstanceID" => 0,
          "EQType" => eq_type,
          "DesiredValue" => value.to_i
        }
      )
    end

    def manual_override_detected?(udn, current_eq)
      expected = @last_applied[udn]
      return false if expected.nil?

      eq_different?(current_eq, expected)
    end

    def observe_override_candidate(udn, track_ctx, current_eq, cfg)
      candidate = @override_candidates[udn]
      same_identity = candidate &&
                      candidate[:track_key] == track_ctx[:track_key] &&
                      eq_equal?(candidate[:eq], current_eq)

      if same_identity
        candidate[:last_seen_at] = Time.now
      else
        @override_candidates[udn] = {
          device_id: track_ctx[:device_id],
          room_name: track_ctx[:room_name],
          title: track_ctx[:title],
          artist: track_ctx[:artist],
          track_key: track_ctx[:track_key],
          eq: current_eq,
          first_seen_at: Time.now,
          last_seen_at: Time.now,
          debounce_sec: cfg.dig("network", "manual_override_debounce_sec").to_i
        }
        puts "#{timestamp} room=#{track_ctx[:room_name]} override_candidate=#{current_eq}"
      end
    end

    def finalize_override_candidate(udn, discard_if_unstable: false)
      candidate = @override_candidates[udn]
      return if candidate.nil?

      elapsed = Time.now - candidate[:first_seen_at]
      required = [candidate[:debounce_sec], 0].max
      if elapsed < required
        @override_candidates.delete(udn) if discard_if_unstable
        return
      end

      preset = @policy.upsert_song_device_override(
        device_id: candidate[:device_id],
        title: candidate[:title],
        artist: candidate[:artist],
        preset: candidate[:eq]
      )
      if preset.nil?
        puts "#{timestamp} room=#{candidate[:room_name]} skip=override_without_track_identity"
        @override_candidates.delete(udn)
        return
      end
      unless @dry_run
        @store.upsert_song_override(
          device_id: candidate[:device_id],
          title: candidate[:title],
          artist: candidate[:artist],
          preset: preset,
          source: "manual_learn"
        )
      end
      action = @dry_run ? "would_learn_song_override" : "learned_song_override"
      puts "#{timestamp} room=#{candidate[:room_name]} device_id=#{candidate[:device_id]} #{action} title=#{candidate[:title].inspect} artist=#{candidate[:artist].inspect} preset=#{preset}"
      @last_applied[udn] = preset
      @override_candidates.delete(udn)
    end

    def sync_devices_registry!(devices, cfg)
      sync_enabled = cfg.dig("network", "sync_devices_registry_on_startup")
      return unless sync_enabled

      @store.upsert_devices(devices)
      registry = @store.load_devices_registry
      puts "#{timestamp} startup_sync devices_registry_updated count=#{registry.size}"
    end

    def select_monitored_devices(devices, cfg)
      target_rooms = Array(cfg["target_rooms"]).map(&:to_s)
      target_ids = Array(cfg["target_device_ids"]).map(&:to_s)
      return devices if target_rooms.empty? && target_ids.empty?

      devices.select do |device|
        target_rooms.include?(device.room_name.to_s) || target_ids.include?(device.udn.to_s)
      end
    end

    def rediscover_monitored_devices(discovery, current_monitored, cfg)
      devices = discovery.discover
      if devices.empty?
        puts "#{timestamp} rediscovery=empty retaining_previous_devices=#{current_monitored.size}"
        return current_monitored
      end

      sync_devices_registry!(devices, cfg) unless @dry_run
      monitored = select_monitored_devices(devices, cfg)
      puts "#{timestamp} rediscovery=updated discovered=#{devices.size} monitored=#{monitored.size}"
      monitored
    rescue StandardError => e
      puts "#{timestamp} rediscovery=error error=#{e.message.inspect} retaining_previous_devices=#{current_monitored.size}"
      current_monitored
    end

    def track_key_for(track_info)
      [track_info[:track_uri], track_info[:title], track_info[:artist]].join("|")
    end

    def playback_context(track_info)
      uri = track_info[:track_uri].to_s
      has_identity = [track_info[:title], track_info[:artist], track_info[:album]].any? { |v| !v.to_s.strip.empty? }

      source_type = if uri.start_with?("x-sonos-htastream:")
                      "tv"
                    elsif uri.start_with?("x-rincon-stream:")
                      "line_in"
                    elsif uri.start_with?("x-rincon-queue:")
                      "queue"
                    elsif uri.start_with?("x-sonosapi-stream:")
                      "radio"
                    elsif uri.start_with?("x-sonosapi-", "x-sonos-spotify:", "x-sonos-http:")
                      "service"
                    elsif uri.start_with?("x-file-cifs:", "file:")
                      "file"
                    elsif uri.start_with?("http://", "https://")
                      "http"
                    elsif uri.empty? && has_identity
                      "metadata_only"
                    else
                      "unknown"
                    end

      music_source = %w[queue radio service file http metadata_only].include?(source_type)

      {
        source_type: source_type,
        has_identity: has_identity,
        music_source: music_source,
        manageable: music_source && has_identity
      }
    end

    def eq_equal?(a, b)
      keys = (a.keys + b.keys).uniq
      keys.all? { |k| normalize_eq_value(k, a[k]) == normalize_eq_value(k, b[k]) }
    end

    def eq_matches_target?(current, target)
      target.keys.all? { |k| normalize_eq_value(k, current[k]) == normalize_eq_value(k, target[k]) }
    end

    def normalize_eq_value(key, value)
      return (!!value) if key == "loudness"
      return value.to_i unless value.nil?

      nil
    end

    def merge_preset_onto_current(current_eq, target_preset)
      out = current_eq.dup
      target_preset.each do |k, v|
        out[k] = v
      end
      out
    end

    def eq_different?(a, b)
      !eq_equal?(a, b)
    end

    def ht_music_enabled_for_room?(room_name, cfg)
      ht = cfg["home_theater_music"] || {}
      return false unless ht.fetch("enabled", false)

      rooms = Array(ht["rooms"]).map(&:to_s)
      return true if rooms.empty?

      rooms.include?(room_name.to_s)
    end

    def cooldown_active?(udn, cooldown_sec)
      return false if cooldown_sec <= 0

      last = @last_apply_at[udn]
      return false if last.nil?

      Time.now - last < cooldown_sec
    end

    def timestamp
      Time.now.iso8601
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def db_path_from_config(cfg)
      Config.db_path(cfg, @config_path)
    end

  end
end
