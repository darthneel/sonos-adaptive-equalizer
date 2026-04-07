# frozen_string_literal: true

module SonosEq
  class GenreNormalizer
    BUILTIN_ALIASES = {
      "rock" => [
        "rock", "alternative", "alt rock", "alternative rock", "indie rock",
        "punk", "punk rock", "grunge", "metal", "hard rock"
      ],
      "hip_hop" => [
        "hip hop", "hip-hop", "rap", "trap", "drill"
      ],
      "electronic" => [
        "electronic", "edm", "dance", "dance pop", "house", "techno", "electro",
        "electropop", "synthpop", "dnb", "drum and bass", "garage"
      ],
      "jazz" => [
        "jazz", "bebop", "fusion", "swing", "smooth jazz"
      ],
      "classical" => [
        "classical", "symphony", "concerto", "orchestra", "orchestral", "opera", "chamber music"
      ],
      "podcast" => [
        "podcast", "talk", "news", "spoken word"
      ],
      "pop" => [
        "pop", "k-pop", "kpop", "indie pop", "ambient pop"
      ],
      "r_and_b" => [
        "r&b", "rnb", "contemporary r&b", "soul", "neo soul", "neo-soul"
      ],
      "country" => [
        "country", "americana", "alt-country", "folk", "singer-songwriter"
      ],
      "ambient" => [
        "ambient", "new age", "downtempo", "chillout"
      ]
    }.freeze

    def initialize(genre_presets)
      @alias_to_canonical = {}
      BUILTIN_ALIASES.each do |canonical, aliases|
        add_aliases(canonical, aliases)
      end

      genre_presets.each do |canonical, preset|
        add_aliases(canonical.to_s, [canonical.to_s] + Array(preset["match"]).map(&:to_s))
      end
    end

    def normalize_text(text)
      candidates = tokenize(text)
      pick_best(candidates)
    end

    def normalize_candidates(candidates)
      flat = Array(candidates).flatten.compact.map(&:to_s)
      pick_best(flat)
    end

    private

    def add_aliases(canonical, aliases)
      aliases.each do |alias_name|
        normalized = normalize_key(alias_name)
        next if normalized.empty?

        @alias_to_canonical[normalized] = canonical
      end
    end

    def pick_best(candidates)
      scores = Hash.new(0)

      candidates.each do |candidate|
        normalized_candidate = normalize_key(candidate)
        next if normalized_candidate.empty?

        @alias_to_canonical.each do |alias_name, canonical|
          next unless normalized_candidate.include?(alias_name)

          score = normalized_candidate == alias_name ? 3 : 1
          scores[canonical] += score
        end
      end

      return "unknown" if scores.empty?

      scores.max_by { |canonical, score| [score, canonical.length] }.first
    end

    def tokenize(text)
      value = text.to_s
      return [] if value.strip.empty?

      parts = value.split(/[\/,;|]/).map(&:strip)
      parts << value
      parts.uniq
    end

    def normalize_key(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end
  end
end
