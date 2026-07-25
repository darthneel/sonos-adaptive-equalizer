# frozen_string_literal: true

require "json"
require "time"

module SonosEq
  class EventLogger
    FORMATS = %w[text json].freeze

    def initialize(io: $stdout, format: "text")
      raise ArgumentError, "Unsupported log format: #{format}" unless FORMATS.include?(format.to_s)

      @io = io
      @format = format.to_s
    end

    def event(name, level: "info", **fields)
      payload = {
        timestamp: Time.now.iso8601,
        level: level,
        event: name
      }.merge(fields.compact)

      line = if @format == "json"
               JSON.generate(payload)
             else
               payload.map { |key, value| "#{key}=#{format_value(value)}" }.join(" ")
             end
      @io.puts(line)
      @io.flush
    end

    private

    def format_value(value)
      case value
      when String then value.inspect
      when Hash, Array then JSON.generate(value)
      else value.inspect
      end
    end
  end
end
