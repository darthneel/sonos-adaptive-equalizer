# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"
require_relative "config"
require_relative "store"

module SonosEq
  class OverrideCli
    COMMANDS = %w[list export set-song set-artist delete-song delete-artist].freeze

    def self.run(argv, out: $stdout)
      command = argv.shift.to_s
      raise OptionParser::InvalidArgument, "command must be one of: #{COMMANDS.join(', ')}" unless COMMANDS.include?(command)

      options = {
        config_path: File.expand_path("../../config/settings.yml", __dir__),
        loudness: true
      }
      parser = build_parser(options)
      parser.parse!(argv)

      config = Config.load(options[:config_path])
      store = Store.new(db_path: Config.db_path(config, options[:config_path]))
      store.setup!
      store.import_legacy!(config: config, config_dir: File.dirname(File.expand_path(options[:config_path])))
      execute(command, options, store, out)
    ensure
      store&.close
    end

    def self.build_parser(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: bin/sonos_eq_overrides COMMAND [options]"
        parser.on("-c", "--config PATH", "Path to YAML config") { |value| options[:config_path] = value }
        parser.on("--artist NAME", "Artist name") { |value| options[:artist] = value }
        parser.on("--title TITLE", "Song title") { |value| options[:title] = value }
        parser.on("--device ID", "Optional device ID for a per-device song override") { |value| options[:device_id] = value }
        parser.on("--bass N", Integer, "Bass from -10 to 10") { |value| options[:bass] = value }
        parser.on("--treble N", Integer, "Treble from -10 to 10") { |value| options[:treble] = value }
        parser.on("--[no-]loudness", "Enable or disable loudness") { |value| options[:loudness] = value }
        parser.on("--sub-gain N", Integer, "Sub gain from -15 to 15") { |value| options[:sub_gain] = value }
        parser.on("--surround-level N", Integer, "Surround level from -15 to 15") { |value| options[:surround_level] = value }
      end
    end
    private_class_method :build_parser

    def self.execute(command, options, store, out)
      case command
      when "list"
        out.puts JSON.pretty_generate(store.load_overrides)
      when "export"
        out.puts YAML.dump("overrides" => store.load_overrides)
      when "set-song"
        require_song_identity!(options)
        preset = validated_preset(options)
        if options[:device_id].to_s.empty?
          store.upsert_global_song_override(artist: options[:artist], title: options[:title], preset: preset, source: "cli")
        else
          store.upsert_song_override(
            device_id: options[:device_id],
            artist: options[:artist],
            title: options[:title],
            preset: preset,
            source: "cli"
          )
        end
        out.puts "Saved song override"
      when "set-artist"
        require_value!(options[:artist], "--artist")
        store.upsert_artist_override(artist: options[:artist], preset: validated_preset(options), source: "cli")
        out.puts "Saved artist override"
      when "delete-song"
        require_song_identity!(options)
        count = store.delete_song_override(
          artist: options[:artist],
          title: options[:title],
          device_id: options[:device_id]
        )
        out.puts "Deleted #{count} song override(s)"
      when "delete-artist"
        require_value!(options[:artist], "--artist")
        out.puts "Deleted #{store.delete_artist_override(artist: options[:artist])} artist override(s)"
      end
    end
    private_class_method :execute

    def self.validated_preset(options)
      bass = options.fetch(:bass, 0)
      treble = options.fetch(:treble, 0)
      raise OptionParser::InvalidArgument, "--bass must be from -10 to 10" unless bass.between?(-10, 10)
      raise OptionParser::InvalidArgument, "--treble must be from -10 to 10" unless treble.between?(-10, 10)

      preset = {
        "bass" => bass,
        "treble" => treble,
        "loudness" => options[:loudness]
      }
      if options.key?(:sub_gain)
        raise OptionParser::InvalidArgument, "--sub-gain must be from -15 to 15" unless options[:sub_gain].between?(-15, 15)

        preset["sub_gain"] = options[:sub_gain]
      end
      if options.key?(:surround_level)
        unless options[:surround_level].between?(-15, 15)
          raise OptionParser::InvalidArgument, "--surround-level must be from -15 to 15"
        end

        preset["surround_level"] = options[:surround_level]
      end
      preset
    end
    private_class_method :validated_preset

    def self.require_song_identity!(options)
      return unless options[:artist].to_s.strip.empty? && options[:title].to_s.strip.empty?

      raise OptionParser::MissingArgument, "--artist or --title"
    end
    private_class_method :require_song_identity!

    def self.require_value!(value, label)
      raise OptionParser::MissingArgument, label if value.to_s.strip.empty?
    end
    private_class_method :require_value!
  end
end
