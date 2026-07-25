# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "timeout"

module SonosEq
  class GenreEnricher
    def initialize(config:, store:, normalizer:, cache_writes: true)
      @enabled = config.fetch("enabled", true)
      @providers = Array(config["providers"]).map(&:to_s)
      @providers = %w[lastfm musicbrainz itunes] if @providers.empty?
      @cache_ttl_sec = config.fetch("cache_ttl_sec", 86_400).to_i
      @negative_cache_ttl_sec = config.fetch("negative_cache_ttl_sec", 21_600).to_i
      @max_cache_size_bytes = config.fetch("max_cache_size_bytes", 5 * 1024 * 1024).to_i
      @compact_to_ratio = config.fetch("compact_to_ratio", 0.6).to_f
      @provider_timeout_sec = config.fetch("provider_timeout_sec", 8).to_f
      @lookup_budget_sec = config.fetch("lookup_budget_sec", 15).to_f
      @provider_failure_backoff_sec = config.fetch("provider_failure_backoff_sec", 300).to_f
      @musicbrainz_min_interval_sec = config.fetch("musicbrainz_min_interval_sec", 1.1).to_f
      @user_agent = config.fetch("user_agent", "sonos-eq-daemon/0.1 (local)")
      @lastfm_api_key = resolve_lastfm_api_key(config["lastfm"] || {})
      @store = store
      @normalizer = normalizer
      @cache_writes = cache_writes
      @provider_backoff_until = {}
      @last_musicbrainz_request_at = nil
    end

    def resolve(track_info)
      return { genre: nil, source: nil } unless @enabled

      title = track_info[:title].to_s.strip
      artist = track_info[:artist].to_s.strip
      return { genre: nil, source: nil } if title.empty? && artist.empty?

      cached = @store.read_genre_cache(
        artist: artist,
        title: title,
        ttl_sec: @cache_ttl_sec,
        negative_ttl_sec: @negative_cache_ttl_sec
      )
      return cached if cached

      started_at = monotonic_now
      complete_miss = true
      @providers.each do |provider|
        if provider_backed_off?(provider)
          complete_miss = false
          next
        end

        remaining = @lookup_budget_sec - (monotonic_now - started_at)
        if remaining <= 0
          complete_miss = false
          break
        end

        raw_candidates = Timeout.timeout([remaining, @provider_timeout_sec].min) do
          lookup_provider(provider, artist, title)
        end
        genre = @normalizer.normalize_candidates(raw_candidates)
        next if genre == "unknown"

        result = { genre: genre, source: provider }
        if @cache_writes
          @store.write_genre_cache(artist: artist, title: title, genre: genre, provider: provider)
          @store.compact_genre_cache!(max_bytes: @max_cache_size_bytes, compact_to_ratio: @compact_to_ratio)
        end
        return result
      rescue StandardError => e
        complete_miss = false
        @provider_backoff_until[provider] = monotonic_now + @provider_failure_backoff_sec
        warn "genre_lookup provider=#{provider.inspect} error=#{e.class}: #{e.message}"
      end

      if complete_miss && @cache_writes
        @store.write_genre_cache_miss(artist: artist, title: title)
        @store.compact_genre_cache!(max_bytes: @max_cache_size_bytes, compact_to_ratio: @compact_to_ratio)
      end
      { genre: nil, source: nil }
    end

    private

    def resolve_lastfm_api_key(lastfm_cfg)
      direct = lastfm_cfg.fetch("api_key", "").to_s.strip
      return direct unless direct.empty?

      env_name = lastfm_cfg.fetch("api_key_env", "LASTFM_API_KEY").to_s
      ENV.fetch(env_name, "").to_s.strip
    end

    def lookup_provider(provider, artist, title)
      case provider
      when "lastfm" then lookup_lastfm(artist, title)
      when "musicbrainz" then lookup_musicbrainz(artist, title)
      when "itunes" then lookup_itunes(artist, title)
      else []
      end
    end

    def lookup_lastfm(artist, title)
      return nil if @lastfm_api_key.to_s.empty?
      return nil if artist.empty? || title.empty?

      uri = URI("https://ws.audioscrobbler.com/2.0/")
      uri.query = URI.encode_www_form(
        method: "track.getTopTags",
        artist: artist,
        track: title,
        api_key: @lastfm_api_key,
        format: "json"
      )
      json = http_json(uri)
      tags = json.dig("toptags", "tag")
      return [] unless tags.is_a?(Array) && !tags.empty?

      tags.map { |tag| tag["name"].to_s.strip }
    end

    def lookup_musicbrainz(artist, title)
      return nil if artist.empty? && title.empty?

      query_bits = []
      query_bits << %(artist:"#{artist}") unless artist.empty?
      query_bits << %(recording:"#{title}") unless title.empty?
      query = query_bits.join(" AND ")

      search_uri = URI("https://musicbrainz.org/ws/2/recording")
      search_uri.query = URI.encode_www_form(query: query, fmt: "json", limit: 1)
      search = http_json(search_uri)
      recording = Array(search["recordings"]).first
      return [] if recording.nil?

      detail_uri = URI("https://musicbrainz.org/ws/2/recording/#{recording['id']}")
      detail_uri.query = URI.encode_www_form(inc: "genres+tags", fmt: "json")
      detail = http_json(detail_uri)

      genres = Array(detail["genres"])
      unless genres.empty?
        return genres
          .sort_by { |g| -g.fetch("count", 0).to_i }
          .map { |g| g["name"].to_s.strip }
      end

      tags = Array(detail["tags"])
      return [] if tags.empty?

      tags
        .sort_by { |t| -t.fetch("count", 0).to_i }
        .map { |t| t["name"].to_s.strip }
    end

    def lookup_itunes(artist, title)
      term = [artist, title].reject(&:empty?).join(" ").strip
      return nil if term.empty?

      uri = URI("https://itunes.apple.com/search")
      uri.query = URI.encode_www_form(term: term, entity: "song", limit: 5)
      json = http_json(uri)
      results = Array(json["results"])
      return [] if results.empty?

      desired_artist = artist.downcase
      desired_title = title.downcase
      best = results.find do |row|
        row_artist = row["artistName"].to_s.downcase
        row_track = row["trackName"].to_s.downcase
        artist_ok = desired_artist.empty? || row_artist.include?(desired_artist)
        title_ok = desired_title.empty? || row_track.include?(desired_title)
        artist_ok && title_ok
      end
      best ||= results.first

      [best["primaryGenreName"].to_s.strip]
    end

    def http_json(uri)
      throttle_musicbrainz if uri.host == "musicbrainz.org"
      response_body = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 6) do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = @user_agent
        response = http.request(request)
        raise "HTTP #{response.code}" unless response.code.to_i == 200

        response.body
      end
      JSON.parse(response_body)
    end

    def throttle_musicbrainz
      if @last_musicbrainz_request_at
        remaining = @musicbrainz_min_interval_sec - (monotonic_now - @last_musicbrainz_request_at)
        sleep remaining if remaining.positive?
      end
      @last_musicbrainz_request_at = monotonic_now
    end

    def provider_backed_off?(provider)
      @provider_backoff_until.fetch(provider, 0) > monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
