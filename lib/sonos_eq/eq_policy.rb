# frozen_string_literal: true

module SonosEq
  class EqPolicy
    Resolution = Struct.new(:preset, :source, keyword_init: true)

    def initialize(default_preset, genre_presets, overrides = {})
      @default_preset = normalize(default_preset)
      @genre_presets = genre_presets.transform_keys(&:to_s).transform_values { |v| normalize(v) }
      @overrides = normalize_overrides(overrides)
    end

    def resolve(device_id:, room_name:, title:, artist:, genre:)
      song_key = song_key(title: title, artist: artist)
      artist_key = artist_key(artist)

      if song_key
        device_song = @overrides.dig("songs", "by_device", device_id.to_s, song_key)
        return Resolution.new(preset: device_song, source: "song+device") if device_song

        global_song = @overrides.dig("songs", "global", song_key)
        return Resolution.new(preset: global_song, source: "song") if global_song
      end

      global_artist = @overrides.dig("artists", "global", artist_key)
      return Resolution.new(preset: global_artist, source: "artist") if global_artist

      genre_preset = @genre_presets[genre.to_s]
      return Resolution.new(preset: genre_preset, source: "genre") if genre_preset

      Resolution.new(preset: @default_preset, source: "default")
    end

    def upsert_song_device_override(device_id:, title:, artist:, preset:)
      device = device_id.to_s
      key = song_key(title: title, artist: artist)
      return nil unless key
      normalized = normalize(preset)

      @overrides["songs"]["by_device"][device] ||= {}
      @overrides["songs"]["by_device"][device][key] = normalized
      normalized
    end

    def overrides_hash
      @overrides
    end

    def song_key(title:, artist:)
      artist_part = sanitize_key(artist)
      title_part = sanitize_key(title)
      return nil if artist_part.empty? && title_part.empty?
      return title_part if artist_part.empty?
      return artist_part if title_part.empty?

      "#{artist_part} - #{title_part}"
    end

    def artist_key(artist)
      sanitize_key(artist)
    end

    private

    def normalize_overrides(overrides)
      songs = overrides.fetch("songs", overrides.fetch(:songs, {}))
      artists = overrides.fetch("artists", overrides.fetch(:artists, {}))

      songs_global = normalize_preset_hash(songs.fetch("global", songs.fetch(:global, {})))
      songs_by_device_raw = songs.fetch("by_device", songs.fetch(:by_device, {}))
      songs_by_device = songs_by_device_raw.each_with_object({}) do |(device_id, mapping), acc|
        acc[device_id.to_s] = normalize_preset_hash(mapping || {})
      end
      artists_global = normalize_preset_hash(artists.fetch("global", artists.fetch(:global, {})))

      {
        "songs" => {
          "global" => songs_global,
          "by_device" => songs_by_device
        },
        "artists" => {
          "global" => artists_global
        }
      }
    end

    def normalize_preset_hash(hash)
      (hash || {}).each_with_object({}) do |(k, v), acc|
        acc[sanitize_key(k)] = normalize(v)
      end
    end

    def normalize(input)
      bass = clamp(input.fetch("bass", input.fetch(:bass, 0)).to_i, -10, 10)
      treble = clamp(input.fetch("treble", input.fetch(:treble, 0)).to_i, -10, 10)
      loudness_raw = input.fetch("loudness", input.fetch(:loudness, true))
      loudness = to_bool(loudness_raw)
      sub_gain_raw = fetch_optional(input, "sub_gain")
      surround_level_raw = fetch_optional(input, "surround_level")

      out = { "bass" => bass, "treble" => treble, "loudness" => loudness }
      out["sub_gain"] = clamp(sub_gain_raw.to_i, -15, 15) unless sub_gain_raw.nil?
      out["surround_level"] = clamp(surround_level_raw.to_i, -15, 15) unless surround_level_raw.nil?
      out
    end

    def to_bool(value)
      return value if value == true || value == false
      return true if value.to_s.strip == "1"
      return false if value.to_s.strip == "0"

      normalized = value.to_s.strip.downcase
      return false if normalized == "false"
      return false if normalized == "no"
      return false if normalized == "off"

      !normalized.empty?
    end

    def sanitize_key(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end

    def fetch_optional(input, key)
      return input[key] if input.key?(key)
      sym = key.to_sym
      return input[sym] if input.key?(sym)

      nil
    end

    def clamp(value, min, max)
      [[value, min].max, max].min
    end
  end
end
