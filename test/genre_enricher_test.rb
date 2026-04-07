# frozen_string_literal: true

require_relative "test_helper"

class GenreEnricherTest < Minitest::Test
  class FakeStore
    attr_reader :writes, :compact_calls

    def initialize(cached: nil)
      @cached = cached
      @writes = []
      @compact_calls = []
    end

    def read_genre_cache(artist:, title:, ttl_sec:)
      @read_args = { artist: artist, title: title, ttl_sec: ttl_sec }
      @cached
    end

    def write_genre_cache(artist:, title:, genre:, provider:)
      @writes << { artist: artist, title: title, genre: genre, provider: provider }
    end

    def compact_genre_cache_by_db_size!(max_bytes:, compact_to_ratio:)
      @compact_calls << { max_bytes: max_bytes, compact_to_ratio: compact_to_ratio }
    end
  end

  class TestGenreEnricher < SonosEq::GenreEnricher
    attr_reader :calls

    def initialize(**kwargs)
      super
      @calls = []
    end

    def lookup_lastfm(artist, title)
      @calls << [:lastfm, artist, title]
      @lastfm_result
    end

    def lookup_musicbrainz(artist, title)
      @calls << [:musicbrainz, artist, title]
      @musicbrainz_result
    end

    def lookup_itunes(artist, title)
      @calls << [:itunes, artist, title]
      @itunes_result
    end

    attr_writer :lastfm_result, :musicbrainz_result, :itunes_result
  end

  def build_enricher(store)
    normalizer = SonosEq::GenreNormalizer.new(
      "rock" => { "match" => ["rock", "alternative"] },
      "electronic" => { "match" => ["electronic", "dance", "edm"] },
      "pop" => { "match" => ["pop", "k-pop"] }
    )

    TestGenreEnricher.new(
      config: {
        "enabled" => true,
        "providers" => %w[lastfm musicbrainz itunes],
        "cache_ttl_sec" => 100,
        "max_cache_size_bytes" => 1234,
        "compact_to_ratio" => 0.5
      },
      store: store,
      normalizer: normalizer
    )
  end

  def test_cache_hit_returns_without_provider_calls
    store = FakeStore.new(cached: { genre: "rock", source: "cache" })
    enricher = build_enricher(store)

    result = enricher.resolve(title: "Song", artist: "Artist")

    assert_equal({ genre: "rock", source: "cache" }, result)
    assert_empty enricher.calls
    assert_empty store.writes
  end

  def test_successful_lookup_writes_cache_and_compacts
    store = FakeStore.new
    enricher = build_enricher(store)
    enricher.musicbrainz_result = ["ambient", "electronic", "pop"]

    result = enricher.resolve(title: "Song", artist: "Artist")

    assert_equal({ genre: "electronic", source: "musicbrainz" }, result)
    assert_equal [[:lastfm, "Artist", "Song"], [:musicbrainz, "Artist", "Song"]], enricher.calls
    assert_equal 1, store.writes.length
    assert_equal "electronic", store.writes.first[:genre]
    assert_equal "musicbrainz", store.writes.first[:provider]
    assert_equal 1, store.compact_calls.length
  end

  def test_miss_does_not_write_negative_cache
    store = FakeStore.new
    enricher = build_enricher(store)

    result = enricher.resolve(title: "Song", artist: "Artist")

    assert_equal({ genre: nil, source: nil }, result)
    assert_empty store.writes
    assert_empty store.compact_calls
  end
end
