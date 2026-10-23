# frozen_string_literal: true

require "json"
require_relative "tts_mp3_export_probe"

# Load argv before substitution: quoted book text must never become JSON syntax.
if $PROGRAM_NAME == __FILE__
  begin
    raise ArgumentError, "Usage: ENGINE_JSON TEXT_FILE OUTPUT_MP3" unless ARGV.length == 3
    engine_path, text_path, output = ARGV
    engine = JSON.parse(File.read(engine_path))
    generated = output + ".source.wav"
    replacements = { "{text}" => File.read(text_path), "{text_file}" => text_path, "{output}" => generated }
    argv = engine.fetch("argv").map do |argument|
      argument.gsub(/\{(?:text|text_file|output)\}/) { |token| replacements.fetch(token) }
    end
    exit TTSMP3ExportProbe.run(argv: argv, generated: generated, output: output, source_format: "wav")
  rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError => error
    warn error.message
    exit 2
  end
end
