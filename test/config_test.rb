# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_load_applies_defaults
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, "settings.yml")
      File.write(path, "---\n{}\n")

      config = SonosEq::Config.load(path)

      assert_equal 5, config.dig("network", "poll_interval_sec")
      assert_equal [], config["target_device_ids"]
      assert_equal false, config.dig("home_theater_music", "enabled")
    end
  end

  def test_rejects_poll_interval_that_would_create_a_hot_loop
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, "settings.yml")
      File.write(path, "---\nnetwork:\n  poll_interval_sec: 0\n")

      error = assert_raises(SonosEq::Config::Error) { SonosEq::Config.load(path) }

      assert_includes error.message, "poll_interval_sec"
    end
  end

  def test_rejects_out_of_range_presets
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, "settings.yml")
      File.write(path, "---\ndefaults:\n  bass: 11\n")

      error = assert_raises(SonosEq::Config::Error) { SonosEq::Config.load(path) }

      assert_includes error.message, "defaults.bass"
    end
  end
end
