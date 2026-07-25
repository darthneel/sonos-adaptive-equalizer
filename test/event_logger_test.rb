# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class EventLoggerTest < Minitest::Test
  def test_json_format_emits_machine_readable_event
    output = StringIO.new
    logger = SonosEq::EventLogger.new(io: output, format: "json")

    logger.event("eq_applied", room: "Kitchen", preset: { "bass" => 2 })

    payload = JSON.parse(output.string)
    assert_equal "eq_applied", payload["event"]
    assert_equal "Kitchen", payload["room"]
    assert_equal 2, payload.dig("preset", "bass")
  end
end
