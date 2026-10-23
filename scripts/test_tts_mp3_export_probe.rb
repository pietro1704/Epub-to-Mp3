# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "tts_mp3_export_probe"
require_relative "tts_book_benchmark"

class TTSMP3ExportProbeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("mp3 export ")
    @tone = File.join(@root, "tone.wav")
    assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", @tone)
    @source = File.join(@root, "generated.wav")
    @output = File.join(@root, "final.mp3")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_generation_encoding_and_durable_output_retain_identity_and_timing
    argv = [RbConfig.ruby, "-rfileutils", "-e", "FileUtils.cp(*ARGV)", @tone, @source]
    capture_io { @code = TTSMP3ExportProbe.run(argv: argv, generated: @source, output: @output, source_format: "wav") }
    assert_equal 0, @code
    report = JSON.parse(File.read(@output + ".timing.json"))
    assert_equal TTSBookBenchmark.sha(@output), report.fetch("mp3_sha256")
    assert_operator report.fetch("complete_mp3_pipeline_s"), :>, report.fetch("generated_file_available_s")
    assert_equal 0, TTSBookBenchmark.inspect_audio(@output, @root, 10).fetch("validation_exit_code")
  end

  def test_generation_failure_prevents_encoding_and_preserves_actual_exit_status
    capture_io { @code = TTSMP3ExportProbe.run(argv: [RbConfig.ruby, "-e", "exit 7"], generated: @source, output: @output, source_format: "wav") }
    assert_equal 7, @code
    refute File.exist?(@output)
    refute File.exist?(@output + ".encode.stderr")
  end

  def test_existing_output_is_never_overwritten
    File.write(@output, "owned original")
    assert_raises(ArgumentError) { TTSMP3ExportProbe.run(argv: [RbConfig.ruby, "-e", "exit 0"], generated: @source, output: @output, source_format: "wav") }
    assert_equal "owned original", File.read(@output)
  end
end
