# frozen_string_literal: true

require_relative "test_helper"

class EqPolicyTest < Minitest::Test
  def build_policy
    SonosEq::EqPolicy.new(
      { "bass" => 0, "treble" => 0, "loudness" => true },
      {
        "rock" => { "match" => ["rock"], "bass" => 2, "treble" => 1, "loudness" => true }
      },
      {
        "songs" => {
          "global" => {
            "artist x - song y" => { "bass" => 3, "treble" => 3, "loudness" => false }
          },
          "by_device" => {
            "uuid:device-1" => {
              "artist x - song y" => { "bass" => 4, "treble" => 5, "loudness" => true }
            }
          }
        },
        "artists" => {
          "global" => {
            "artist x" => { "bass" => 1, "treble" => 2, "loudness" => false }
          }
        }
      }
    )
  end

  def test_resolution_precedence_prefers_song_device
    policy = build_policy

    result = policy.resolve(
      device_id: "uuid:device-1",
      room_name: "Kitchen",
      title: "Song Y",
      artist: "Artist X",
      genre: "rock"
    )

    assert_equal "song+device", result.source
    assert_equal 4, result.preset["bass"]
  end

  def test_resolution_falls_back_to_song_then_artist_then_genre_then_default
    policy = build_policy

    song_result = policy.resolve(
      device_id: "uuid:device-2",
      room_name: "Kitchen",
      title: "Song Y",
      artist: "Artist X",
      genre: "rock"
    )
    assert_equal "song", song_result.source
    assert_equal 3, song_result.preset["bass"]

    artist_result = policy.resolve(
      device_id: "uuid:device-2",
      room_name: "Kitchen",
      title: "Unknown Song",
      artist: "Artist X",
      genre: "rock"
    )
    assert_equal "artist", artist_result.source
    assert_equal 1, artist_result.preset["bass"]

    genre_result = policy.resolve(
      device_id: "uuid:device-2",
      room_name: "Kitchen",
      title: "Unknown Song",
      artist: "Unknown Artist",
      genre: "rock"
    )
    assert_equal "genre", genre_result.source
    assert_equal 2, genre_result.preset["bass"]

    default_result = policy.resolve(
      device_id: "uuid:device-2",
      room_name: "Kitchen",
      title: "Unknown Song",
      artist: "Unknown Artist",
      genre: "unknown"
    )
    assert_equal "default", default_result.source
    assert_equal 0, default_result.preset["bass"]
  end

  def test_normalization_clamps_and_preserves_false_loudness
    policy = SonosEq::EqPolicy.new(
      { "bass" => 99, "treble" => -99, "loudness" => false, "sub_gain" => 42, "surround_level" => -42 },
      {},
      {}
    )

    result = policy.resolve(
      device_id: "uuid:device-1",
      room_name: "Living Room",
      title: "Song",
      artist: "Artist",
      genre: "unknown"
    )

    assert_equal(-10, result.preset["treble"])
    assert_equal(10, result.preset["bass"])
    assert_equal false, result.preset["loudness"]
    assert_equal 15, result.preset["sub_gain"]
    assert_equal(-15, result.preset["surround_level"])
  end
end
