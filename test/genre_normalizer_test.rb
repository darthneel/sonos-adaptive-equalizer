# frozen_string_literal: true

require_relative "test_helper"

class GenreNormalizerTest < Minitest::Test
  def build_normalizer
    SonosEq::GenreNormalizer.new(
      "rock" => { "match" => ["rock", "alternative", "indie"] },
      "hip_hop" => { "match" => ["hip hop", "rap", "trap"] },
      "electronic" => { "match" => ["electronic", "dance", "edm"] },
      "jazz" => { "match" => ["jazz"] },
      "classical" => { "match" => ["classical"] },
      "podcast" => { "match" => ["podcast", "news"] }
    )
  end

  def test_normalizes_single_provider_label_to_canonical_genre
    normalizer = build_normalizer

    assert_equal "rock", normalizer.normalize_candidates(["Alternative"])
    assert_equal "hip_hop", normalizer.normalize_candidates(["rap"])
    assert_equal "electronic", normalizer.normalize_candidates(["dance pop"])
  end

  def test_scores_multiple_candidates_and_prefers_best_match
    normalizer = build_normalizer

    assert_equal "electronic", normalizer.normalize_candidates(["ambient", "electronic", "pop"])
    assert_equal "rock", normalizer.normalize_candidates(["indie rock", "alternative rock"])
  end

  def test_unknown_when_no_candidate_maps_to_fixed_set
    normalizer = build_normalizer

    assert_equal "unknown", normalizer.normalize_candidates(["glitch noir"])
  end
end
