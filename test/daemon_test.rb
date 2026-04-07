# frozen_string_literal: true

require_relative "test_helper"

class DaemonTest < Minitest::Test
  Device = Struct.new(:udn, :room_name, :model_name, :ip, :av_transport_control_url, :rendering_control_url, keyword_init: true)

  class FakePolicy
    Resolution = Struct.new(:preset, :source)
    attr_reader :upserts

    def initialize(preset: { "bass" => 1, "treble" => 1, "loudness" => true })
      @preset = preset
      @upserts = []
    end

    def resolve(**)
      Resolution.new(@preset, "default")
    end

    def upsert_song_device_override(device_id:, title:, artist:, preset:)
      @upserts << { device_id: device_id, title: title, artist: artist, preset: preset }
      preset
    end
  end

  class FakeStore
    attr_reader :override_writes

    def initialize
      @override_writes = []
    end

    def upsert_song_override(**kwargs)
      @override_writes << kwargs
    end
  end

  class FakeClassifier
    def detect(_track_info)
      "rock"
    end

    def canonicalize(value)
      value
    end
  end

  class FakeEnricher
    def resolve(_track_info)
      { genre: nil, source: nil }
    end
  end

  def build_daemon
    daemon = SonosEq::Daemon.new("/tmp/sonos_eq_test.yml", once: true)
    daemon.instance_variable_set(:@policy, FakePolicy.new)
    daemon.instance_variable_set(:@store, FakeStore.new)
    daemon
  end

  def device
    Device.new(
      udn: "uuid:device-1",
      room_name: "Living Room",
      model_name: "Beam",
      ip: "192.168.1.10",
      av_transport_control_url: "http://example/av",
      rendering_control_url: "http://example/rc"
    )
  end

  def test_unmanaged_playback_skips_eq_write
    daemon = build_daemon
    applied = []
    daemon.define_singleton_method(:current_track_info) do |_device|
      { track_uri: "", title: "", artist: "", album: "", track_metadata_xml: "" }
    end
    daemon.define_singleton_method(:apply_eq) { |_device, _preset, include_ht_music:| applied << include_ht_music }

    daemon.send(:process_device, device, FakeClassifier.new, FakeEnricher.new, daemon.instance_variable_get(:@policy), { "network" => {} })

    assert_empty applied
  end

  def test_ht_controls_only_enabled_for_music_source
    daemon = build_daemon
    include_ht_values = []
    daemon.define_singleton_method(:current_track_info) do |_device|
      {
        track_uri: "x-rincon-queue:RINCON_123#0",
        title: "Song",
        artist: "Artist",
        album: "Album",
        track_metadata_xml: ""
      }
    end
    daemon.define_singleton_method(:current_eq) do |_device, include_ht_music:|
      include_ht_values << include_ht_music
      { "bass" => 0, "treble" => 0, "loudness" => true }
    end
    daemon.define_singleton_method(:apply_eq) { |_device, _preset, include_ht_music:| include_ht_values << include_ht_music }

    cfg = { "network" => {}, "home_theater_music" => { "enabled" => true, "rooms" => ["Living Room"] } }
    daemon.send(:process_device, device, FakeClassifier.new, FakeEnricher.new, daemon.instance_variable_get(:@policy), cfg)

    assert_equal [true, true], include_ht_values
  end

  def test_manual_override_candidate_persists_on_finalize
    daemon = build_daemon
    policy = daemon.instance_variable_get(:@policy)
    store = daemon.instance_variable_get(:@store)

    daemon.define_singleton_method(:current_track_info) do |_device|
      {
        track_uri: "x-rincon-queue:RINCON_123#0",
        title: "Song",
        artist: "Artist",
        album: "Album",
        track_metadata_xml: ""
      }
    end

    current_eq_calls = 0
    daemon.define_singleton_method(:current_eq) do |_device, include_ht_music:|
      current_eq_calls += 1
      if current_eq_calls == 1
        { "bass" => 0, "treble" => 0, "loudness" => true }
      else
        { "bass" => 4, "treble" => 2, "loudness" => false }
      end
    end
    daemon.define_singleton_method(:apply_eq) { |_device, _preset, include_ht_music:| }

    cfg = { "network" => { "manual_override_debounce_sec" => 0 } }
    daemon.send(:process_device, device, FakeClassifier.new, FakeEnricher.new, policy, cfg)
    daemon.send(:process_device, device, FakeClassifier.new, FakeEnricher.new, policy, cfg)

    assert_equal 1, policy.upserts.length
    assert_equal 1, store.override_writes.length
    assert_equal "uuid:device-1", store.override_writes.first[:device_id]
    assert_equal 4, store.override_writes.first[:preset]["bass"]
  end
end
