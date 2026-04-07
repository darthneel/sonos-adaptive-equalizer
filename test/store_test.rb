# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  Device = Struct.new(:udn, :room_name, :model_name, :ip, keyword_init: true)

  def build_store(tmpdir)
    path = File.join(tmpdir, "sonos_eq.sqlite3")
    store = SonosEq::Store.new(db_path: path)
    store.setup!
    store
  end

  def legacy_config(tmpdir)
    cache_dir = File.join(tmpdir, "config", "tmp")
    FileUtils.mkdir_p(cache_dir)
    File.write(
      File.join(cache_dir, "genre_cache.json"),
      JSON.pretty_generate(
        "artist a||song a" => {
          "genre" => "rock",
          "source" => "itunes",
          "seen_at" => Time.now.iso8601
        }
      )
    )

    {
      "genre_lookup" => { "cache_path" => "tmp/genre_cache.json" },
      "defaults" => { "bass" => 1, "treble" => 2, "loudness" => false },
      "genres" => {
        "rock" => { "match" => ["rock"], "bass" => 3, "treble" => 4, "loudness" => true }
      },
      "overrides" => {
        "songs" => {
          "by_device" => {
            "uuid:device-1" => {
              "artist a - song a" => { "bass" => 5, "treble" => 6, "loudness" => true }
            }
          }
        }
      },
      "devices" => {
        "uuid:device-1" => {
          "room_name" => "Kitchen",
          "model_name" => "Sonos One",
          "ip" => "192.168.1.50",
          "last_seen_at" => Time.now.iso8601
        }
      }
    }
  end

  def test_setup_and_legacy_import
    with_tmpdir do |tmpdir|
      store = build_store(tmpdir)
      config = legacy_config(tmpdir)

      store.import_legacy!(config: config, config_dir: File.join(tmpdir, "config"))

      assert_equal({ "bass" => 1, "treble" => 2, "loudness" => false }, store.load_default_settings)
      assert_equal 3, store.load_genre_presets.dig("rock", "bass")
      assert_equal 5, store.load_song_overrides.dig("uuid:device-1", "artist a - song a", "bass")
      assert_equal "Kitchen", store.load_devices_registry.dig("uuid:device-1", "room_name")

      cached = store.read_genre_cache(artist: "Artist A", title: "Song A", ttl_sec: 1000)
      assert_equal({ genre: "rock", source: "itunes" }, cached)
    end
  end

  def test_upsert_paths_for_overrides_devices_and_cache
    with_tmpdir do |tmpdir|
      store = build_store(tmpdir)

      store.upsert_song_override(
        device_id: "uuid:device-2",
        artist: "Artist B",
        title: "Song B",
        preset: { "bass" => 2, "treble" => 1, "loudness" => true, "sub_gain" => 4 },
        source: "manual_learn"
      )
      assert_equal 2, store.load_song_overrides.dig("uuid:device-2", "artist b - song b", "bass")

      store.upsert_devices([
        Device.new(udn: "uuid:device-2", room_name: "Living Room", model_name: "Beam", ip: "192.168.1.51")
      ])
      assert_equal "Living Room", store.load_devices_registry.dig("uuid:device-2", "room_name")

      store.write_genre_cache(artist: "Artist B", title: "Song B", genre: "pop", provider: "musicbrainz")
      cached = store.read_genre_cache(artist: "Artist B", title: "Song B", ttl_sec: 1000)
      assert_equal({ genre: "pop", source: "musicbrainz" }, cached)
    end
  end
end
