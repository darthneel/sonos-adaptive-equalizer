# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "time"
require "sqlite3"

module SonosEq
  class Store
    def initialize(db_path:)
      @db_path = File.expand_path(db_path)
      FileUtils.mkdir_p(File.dirname(@db_path))
      @db = SQLite3::Database.new(@db_path)
      @db.results_as_hash = true
      configure!
    end

    def setup!
      @db.execute("PRAGMA journal_mode = WAL")
      @db.execute("PRAGMA synchronous = NORMAL")
      @db.execute("PRAGMA foreign_keys = ON")
      @db.execute("PRAGMA busy_timeout = 5000")

      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS app_metadata (
          key TEXT PRIMARY KEY,
          value TEXT,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS default_settings (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          bass INTEGER NOT NULL,
          treble INTEGER NOT NULL,
          loudness INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS genre_presets (
          genre_key TEXT PRIMARY KEY,
          match_keywords_json TEXT NOT NULL,
          bass INTEGER NOT NULL,
          treble INTEGER NOT NULL,
          loudness INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS song_overrides (
          device_id TEXT NOT NULL,
          artist_norm TEXT NOT NULL,
          title_norm TEXT NOT NULL,
          artist_display TEXT,
          title_display TEXT,
          bass INTEGER NOT NULL,
          treble INTEGER NOT NULL,
          loudness INTEGER NOT NULL,
          sub_gain INTEGER,
          surround_level INTEGER,
          source TEXT NOT NULL,
          learned_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (device_id, artist_norm, title_norm)
        );

        CREATE TABLE IF NOT EXISTS devices (
          device_id TEXT PRIMARY KEY,
          room_name TEXT NOT NULL,
          model_name TEXT,
          ip TEXT,
          last_seen_at TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS genre_cache (
          artist_norm TEXT NOT NULL,
          title_norm TEXT NOT NULL,
          artist_display TEXT,
          title_display TEXT,
          genre TEXT NOT NULL,
          provider TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (artist_norm, title_norm)
        );
      SQL
    end

    def import_legacy!(config:, config_dir:)
      return if metadata("legacy_import_completed") == "1"

      now = Time.now.iso8601
      @db.transaction
      import_defaults(config["defaults"] || {}, now)
      import_genre_presets(config["genres"] || {}, now)
      import_song_overrides(config.dig("overrides", "songs", "by_device") || {}, now)
      import_devices(config["devices"] || {}, now)
      import_genre_cache_json(resolve_legacy_genre_cache_path(config, config_dir))
      set_metadata("legacy_import_completed", "1", now)
      @db.commit
    rescue StandardError
      @db.rollback
      raise
    end

    def load_default_settings
      row = @db.get_first_row("SELECT bass, treble, loudness FROM default_settings WHERE id = 1")
      return nil if row.nil?

      {
        "bass" => row["bass"].to_i,
        "treble" => row["treble"].to_i,
        "loudness" => row["loudness"].to_i == 1
      }
    end

    def load_genre_presets
      rows = @db.execute("SELECT genre_key, match_keywords_json, bass, treble, loudness FROM genre_presets ORDER BY genre_key")
      rows.each_with_object({}) do |row, acc|
        acc[row["genre_key"]] = {
          "match" => JSON.parse(row["match_keywords_json"]),
          "bass" => row["bass"].to_i,
          "treble" => row["treble"].to_i,
          "loudness" => row["loudness"].to_i == 1
        }
      end
    end

    def load_song_overrides
      rows = @db.execute(<<~SQL)
        SELECT device_id, artist_norm, title_norm, bass, treble, loudness, sub_gain, surround_level
        FROM song_overrides
      SQL
      rows.each_with_object({}) do |row, acc|
        acc[row["device_id"]] ||= {}
        key = song_key(row["artist_norm"], row["title_norm"])
        acc[row["device_id"]][key] = row_to_preset(row)
      end
    end

    def upsert_song_override(device_id:, artist:, title:, preset:, source:)
      artist_norm = normalize_key(artist)
      title_norm = normalize_key(title)
      return nil if artist_norm.empty? && title_norm.empty?

      now = Time.now.iso8601
      sql = <<~SQL
        INSERT INTO song_overrides (
          device_id, artist_norm, title_norm, artist_display, title_display,
          bass, treble, loudness, sub_gain, surround_level, source, learned_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(device_id, artist_norm, title_norm) DO UPDATE SET
          artist_display = excluded.artist_display,
          title_display = excluded.title_display,
          bass = excluded.bass,
          treble = excluded.treble,
          loudness = excluded.loudness,
          sub_gain = excluded.sub_gain,
          surround_level = excluded.surround_level,
          source = excluded.source,
          updated_at = excluded.updated_at
      SQL
      @db.execute(sql, [
        device_id.to_s,
        artist_norm,
        title_norm,
        artist.to_s,
        title.to_s,
        preset.fetch("bass").to_i,
        preset.fetch("treble").to_i,
        preset.fetch("loudness") ? 1 : 0,
        preset["sub_gain"],
        preset["surround_level"],
        source.to_s,
        now,
        now
      ])

      preset
    end

    def upsert_devices(devices)
      now = Time.now.iso8601
      @db.transaction
      devices.each do |device|
        @db.execute(<<~SQL, [device.udn.to_s, device.room_name.to_s, device.model_name.to_s, device.ip.to_s, now, now, now])
          INSERT INTO devices (device_id, room_name, model_name, ip, last_seen_at, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_id) DO UPDATE SET
            room_name = excluded.room_name,
            model_name = excluded.model_name,
            ip = excluded.ip,
            last_seen_at = excluded.last_seen_at,
            updated_at = excluded.updated_at
        SQL
      end
      @db.commit
    rescue StandardError
      @db.rollback
      raise
    end

    def load_devices_registry
      rows = @db.execute("SELECT device_id, room_name, model_name, ip, last_seen_at FROM devices ORDER BY device_id")
      rows.each_with_object({}) do |row, acc|
        acc[row["device_id"]] = {
          "room_name" => row["room_name"],
          "model_name" => row["model_name"],
          "ip" => row["ip"],
          "last_seen_at" => row["last_seen_at"]
        }
      end
    end

    def read_genre_cache(artist:, title:, ttl_sec:)
      row = @db.get_first_row(
        "SELECT genre, provider, seen_at FROM genre_cache WHERE artist_norm = ? AND title_norm = ?",
        [normalize_key(artist), normalize_key(title)]
      )
      return nil if row.nil?

      seen_at = Time.parse(row["seen_at"].to_s)
      return nil if Time.now - seen_at > ttl_sec.to_i

      { genre: row["genre"], source: row["provider"] }
    rescue StandardError
      nil
    end

    def write_genre_cache(artist:, title:, genre:, provider:)
      now = Time.now.iso8601
      sql = <<~SQL
        INSERT INTO genre_cache (artist_norm, title_norm, artist_display, title_display, genre, provider, seen_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(artist_norm, title_norm) DO UPDATE SET
          artist_display = excluded.artist_display,
          title_display = excluded.title_display,
          genre = excluded.genre,
          provider = excluded.provider,
          seen_at = excluded.seen_at
      SQL
      @db.execute(sql, [
        normalize_key(artist),
        normalize_key(title),
        artist.to_s,
        title.to_s,
        genre.to_s,
        provider.to_s,
        now
      ])
    end

    def compact_genre_cache_by_db_size!(max_bytes:, compact_to_ratio:)
      return if max_bytes.to_i <= 0
      return if db_size_bytes <= max_bytes.to_i

      target_bytes = (max_bytes.to_i * compact_to_ratio.to_f).to_i
      target_bytes = max_bytes.to_i if target_bytes <= 0 || target_bytes >= max_bytes.to_i

      while db_size_bytes > target_bytes
        deleted = @db.execute("DELETE FROM genre_cache WHERE rowid IN (SELECT rowid FROM genre_cache ORDER BY seen_at ASC LIMIT 100)")
        break if deleted.nil?
        break if @db.changes.zero?
      end

      @db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      @db.execute("VACUUM")
    end

    private

    def configure!
      nil
    end

    def metadata(key)
      row = @db.get_first_row("SELECT value FROM app_metadata WHERE key = ?", [key.to_s])
      row && row["value"]
    end

    def set_metadata(key, value, now)
      sql = <<~SQL
        INSERT INTO app_metadata (key, value, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
          value = excluded.value,
          updated_at = excluded.updated_at
      SQL
      @db.execute(sql, [key.to_s, value.to_s, now])
    end

    def import_defaults(defaults, now)
      return unless @db.get_first_value("SELECT COUNT(*) FROM default_settings").to_i.zero?
      return if defaults.empty?

      @db.execute(
        "INSERT INTO default_settings (id, bass, treble, loudness, updated_at) VALUES (1, ?, ?, ?, ?)",
        [defaults.fetch("bass", 0).to_i, defaults.fetch("treble", 0).to_i, truthy?(defaults.fetch("loudness", true)) ? 1 : 0, now]
      )
    end

    def import_genre_presets(genres, now)
      return unless @db.get_first_value("SELECT COUNT(*) FROM genre_presets").to_i.zero?

      genres.each do |genre_key, preset|
        @db.execute(
          "INSERT INTO genre_presets (genre_key, match_keywords_json, bass, treble, loudness, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
          [
            genre_key.to_s,
            JSON.generate(Array(preset["match"]).map(&:to_s)),
            preset.fetch("bass", 0).to_i,
            preset.fetch("treble", 0).to_i,
            truthy?(preset.fetch("loudness", true)) ? 1 : 0,
            now
          ]
        )
      end
    end

    def import_song_overrides(by_device, now)
      return unless @db.get_first_value("SELECT COUNT(*) FROM song_overrides").to_i.zero?

      by_device.each do |device_id, entries|
        entries.each do |song_key, preset|
          artist_norm, title_norm = split_song_key(song_key)
          sql = <<~SQL
            INSERT INTO song_overrides (
              device_id, artist_norm, title_norm, artist_display, title_display,
              bass, treble, loudness, sub_gain, surround_level, source, learned_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          @db.execute(sql, [
            device_id.to_s,
            artist_norm,
            title_norm,
            artist_norm,
            title_norm,
            preset.fetch("bass", 0).to_i,
            preset.fetch("treble", 0).to_i,
            truthy?(preset.fetch("loudness", true)) ? 1 : 0,
            preset["sub_gain"],
            preset["surround_level"],
            "legacy_import",
            now,
            now
          ])
        end
      end
    end

    def import_devices(devices, now)
      return unless @db.get_first_value("SELECT COUNT(*) FROM devices").to_i.zero?

      devices.each do |device_id, entry|
        @db.execute(
          "INSERT INTO devices (device_id, room_name, model_name, ip, last_seen_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [device_id.to_s, entry["room_name"].to_s, entry["model_name"].to_s, entry["ip"].to_s, entry["last_seen_at"].to_s.empty? ? now : entry["last_seen_at"].to_s, now, now]
        )
      end
    end

    def import_genre_cache_json(path)
      return if path.nil? || !File.exist?(path)
      return unless @db.get_first_value("SELECT COUNT(*) FROM genre_cache").to_i.zero?

      payload = JSON.parse(File.read(path))
      payload.each do |cache_key, value|
        artist_norm, title_norm = cache_key.to_s.split("||", 2)
        next if value["genre"].to_s.strip.empty?

        @db.execute(
          "INSERT INTO genre_cache (artist_norm, title_norm, artist_display, title_display, genre, provider, seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [artist_norm.to_s, title_norm.to_s, artist_norm.to_s, title_norm.to_s, value["genre"].to_s, value["source"].to_s, value["seen_at"].to_s]
        )
      end
    rescue StandardError
      nil
    end

    def resolve_legacy_genre_cache_path(config, config_dir)
      candidate = config.dig("genre_lookup", "cache_path").to_s.strip
      candidate = "tmp/genre_cache.json" if candidate.empty?
      return candidate if Pathname.new(candidate).absolute?

      File.expand_path(candidate, config_dir)
    end

    def row_to_preset(row)
      out = {
        "bass" => row["bass"].to_i,
        "treble" => row["treble"].to_i,
        "loudness" => row["loudness"].to_i == 1
      }
      out["sub_gain"] = row["sub_gain"].to_i unless row["sub_gain"].nil?
      out["surround_level"] = row["surround_level"].to_i unless row["surround_level"].nil?
      out
    end

    def normalize_key(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end

    def song_key(artist_norm, title_norm)
      return title_norm if artist_norm.to_s.empty?
      return artist_norm if title_norm.to_s.empty?

      "#{artist_norm} - #{title_norm}"
    end

    def split_song_key(song_key)
      parts = song_key.to_s.split(" - ", 2)
      return [normalize_key(parts[0]), ""] if parts.length == 1

      [normalize_key(parts[0]), normalize_key(parts[1])]
    end

    def truthy?(value)
      return value if value == true || value == false

      !%w[0 false no off].include?(value.to_s.strip.downcase)
    end

    def db_size_bytes
      page_count = @db.get_first_value("PRAGMA page_count").to_i
      page_size = @db.get_first_value("PRAGMA page_size").to_i
      wal_path = "#{@db_path}-wal"
      wal_size = File.exist?(wal_path) ? File.size(wal_path) : 0
      (page_count * page_size) + wal_size
    end
  end
end
