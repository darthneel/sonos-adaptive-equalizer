# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class OverrideCliTest < Minitest::Test
  def test_set_list_export_and_delete_global_song_override
    with_tmpdir do |tmpdir|
      config_path = File.join(tmpdir, "settings.yml")
      File.write(config_path, "---\nstorage:\n  db_path: data/test.sqlite3\n")
      output = StringIO.new

      SonosEq::OverrideCli.run(
        ["set-song", "--config", config_path, "--artist", "Artist", "--title", "Song", "--bass", "3", "--no-loudness"],
        out: output
      )
      output.truncate(0)
      output.rewind
      SonosEq::OverrideCli.run(["list", "--config", config_path], out: output)
      listed = JSON.parse(output.string)
      assert_equal 3, listed.dig("songs", "global", "artist - song", "bass")
      assert_equal false, listed.dig("songs", "global", "artist - song", "loudness")

      output.truncate(0)
      output.rewind
      SonosEq::OverrideCli.run(["export", "--config", config_path], out: output)
      exported = YAML.safe_load(output.string)
      assert_equal 3, exported.dig("overrides", "songs", "global", "artist - song", "bass")

      SonosEq::OverrideCli.run(
        ["delete-song", "--config", config_path, "--artist", "Artist", "--title", "Song"],
        out: output
      )
      store = SonosEq::Store.new(db_path: File.join(tmpdir, "data", "test.sqlite3"), readonly: true)
      assert_empty store.load_global_song_overrides
      store.close
    end
  end
end
