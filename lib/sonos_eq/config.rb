# frozen_string_literal: true

require "yaml"

module SonosEq
  class Config
    class Error < StandardError; end

    DEFAULTS = {
      "network" => {
        "discovery_timeout_sec" => 4,
        "poll_interval_sec" => 5,
        "apply_cooldown_sec" => 20,
        "manual_override_debounce_sec" => 10,
        "rediscovery_interval_sec" => 300,
        "sync_devices_registry_on_startup" => true
      },
      "storage" => {
        "db_path" => "data/sonos_eq.sqlite3"
      },
      "home_theater_music" => {
        "enabled" => false,
        "rooms" => []
      },
      "genre_lookup" => {
        "enabled" => true,
        "providers" => %w[lastfm musicbrainz itunes],
        "cache_ttl_sec" => 2_592_000,
        "negative_cache_ttl_sec" => 21_600,
        "max_cache_size_bytes" => 5 * 1024 * 1024,
        "compact_to_ratio" => 0.6,
        "provider_timeout_sec" => 8,
        "lookup_budget_sec" => 15,
        "provider_failure_backoff_sec" => 300,
        "musicbrainz_min_interval_sec" => 1.1
      },
      "target_rooms" => [],
      "target_device_ids" => [],
      "devices" => {},
      "defaults" => {
        "bass" => 0,
        "treble" => 0,
        "loudness" => true
      },
      "genres" => {},
      "overrides" => {}
    }.freeze

    POSITIVE_NUMBERS = %w[
      network.discovery_timeout_sec
      network.poll_interval_sec
      network.rediscovery_interval_sec
      genre_lookup.provider_timeout_sec
      genre_lookup.lookup_budget_sec
    ].freeze
    NON_NEGATIVE_NUMBERS = %w[
      network.apply_cooldown_sec
      network.manual_override_debounce_sec
      genre_lookup.cache_ttl_sec
      genre_lookup.negative_cache_ttl_sec
      genre_lookup.max_cache_size_bytes
      genre_lookup.provider_failure_backoff_sec
      genre_lookup.musicbrainz_min_interval_sec
    ].freeze
    def self.load(path)
      raw = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      raise Error, "Configuration must contain a YAML mapping" unless raw.is_a?(Hash)

      config = deep_merge(DEFAULTS, raw)
      validate!(config)
      config
    rescue Errno::ENOENT
      raise Error, "Configuration file not found: #{File.expand_path(path)}"
    rescue Psych::Exception => e
      raise Error, "Invalid YAML: #{e.message}"
    end

    def self.validate!(config)
      POSITIVE_NUMBERS.each do |path|
        value = dig_path(config, path)
        raise Error, "#{path} must be greater than zero" unless numeric?(value) && value.to_f.positive?
      end

      NON_NEGATIVE_NUMBERS.each do |path|
        value = dig_path(config, path)
        raise Error, "#{path} must be zero or greater" unless numeric?(value) && value.to_f >= 0
      end

      ratio = config.dig("genre_lookup", "compact_to_ratio")
      unless numeric?(ratio) && ratio.to_f.positive? && ratio.to_f <= 1
        raise Error, "genre_lookup.compact_to_ratio must be greater than zero and at most one"
      end

      validate_string_array!(config, "target_rooms")
      validate_string_array!(config, "target_device_ids")
      validate_string_array!(config["home_theater_music"], "rooms", prefix: "home_theater_music")
      validate_string_array!(config["genre_lookup"], "providers", prefix: "genre_lookup")
      validate_preset!(config["defaults"], "defaults")
      config.fetch("genres", {}).each do |genre, preset|
        raise Error, "genres.#{genre} must be a mapping" unless preset.is_a?(Hash)

        validate_preset!(preset, "genres.#{genre}")
      end

      config
    end

    def self.deep_merge(base, override)
      base.merge(override) do |_key, base_value, override_value|
        if base_value.is_a?(Hash) && override_value.is_a?(Hash)
          deep_merge(base_value, override_value)
        else
          override_value
        end
      end
    end
    private_class_method :deep_merge

    def self.dig_path(config, path)
      path.split(".").reduce(config) { |memo, key| memo.is_a?(Hash) ? memo[key] : nil }
    end
    private_class_method :dig_path

    def self.numeric?(value)
      value.is_a?(Numeric)
    end
    private_class_method :numeric?

    def self.validate_string_array!(mapping, key, prefix: nil)
      value = mapping[key]
      label = [prefix, key].compact.join(".")
      unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
        raise Error, "#{label} must be an array of strings"
      end
    end
    private_class_method :validate_string_array!

    def self.validate_preset!(preset, label)
      raise Error, "#{label} must be a mapping" unless preset.is_a?(Hash)

      %w[bass treble].each do |key|
        value = preset.fetch(key, 0)
        unless value.is_a?(Integer) && value.between?(-10, 10)
          raise Error, "#{label}.#{key} must be an integer from -10 to 10"
        end
      end
      loudness = preset.fetch("loudness", true)
      raise Error, "#{label}.loudness must be true or false" unless [true, false].include?(loudness)
    end
    private_class_method :validate_preset!
  end
end
