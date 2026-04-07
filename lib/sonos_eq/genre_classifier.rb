# frozen_string_literal: true

require "rexml/document"

module SonosEq
  class GenreClassifier
    def initialize(normalizer)
      @normalizer = normalizer
    end

    def detect(track_info)
      declared_genre = extract_declared_genre(track_info[:track_metadata_xml])
      normalized_declared = @normalizer.normalize_candidates([declared_genre])
      return normalized_declared unless normalized_declared == "unknown"

      haystack = [
        track_info[:title],
        track_info[:artist],
        track_info[:album],
        track_info[:track_uri]
      ].compact.join(" ").downcase

      @normalizer.normalize_text(haystack)
    end

    def detect_from_text(text)
      result = @normalizer.normalize_text(text)
      return nil if result == "unknown"

      result
    end

    def canonicalize(genre_text)
      @normalizer.normalize_candidates([genre_text])
    end

    private

    def extract_declared_genre(track_metadata_xml)
      return nil if track_metadata_xml.nil? || track_metadata_xml.empty? || track_metadata_xml == "NOT_IMPLEMENTED"

      doc = REXML::Document.new(track_metadata_xml)
      genre_node = REXML::XPath.first(doc, "//*[local-name()='genre']")
      return nil if genre_node.nil?

      text = genre_node.text.to_s.strip.downcase
      text.empty? ? nil : text
    rescue StandardError
      nil
    end
  end
end
