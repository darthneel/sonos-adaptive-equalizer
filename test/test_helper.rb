# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sonos_eq/eq_policy"
require "sonos_eq/config"
require "sonos_eq/genre_enricher"
require "sonos_eq/genre_normalizer"
require "sonos_eq/store"
require "sonos_eq/daemon"
require "sonos_eq/override_cli"
require "sonos_eq/discovery"
require "sonos_eq/soap_client"
require "sonos_eq/genre_classifier"
require "sonos_eq/event_logger"

module SonosEqTestSupport
  def with_tmpdir
    Dir.mktmpdir("sonos-eq-test") do |dir|
      yield dir
    end
  end
end

class Minitest::Test
  include SonosEqTestSupport
end
