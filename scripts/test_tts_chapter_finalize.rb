# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "tts_chapter_finalize"

class TTSChapterFinalizeTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("chapter export ")
    @report = { "samples" => [], "runs" => [] }
    2.times do |index|
      audio = File.join(@root, "block-#{index}.mp3")
      assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=#{440 + index * 200}:duration=0.3", audio)
      @report["samples"] << { "id" => "chunk-#{index}", "sha256" => "text-#{index}" }
      @report["runs"] << { "sample" => "chunk-#{index}", "sample_sha256" => "text-#{index}", "audio" => audio,
        "audio_sha256" => TTSBookBenchmark.sha(audio), "status" => "validated" }
    end
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def persist
    File.write(File.join(@root, "report.json"), JSON.generate(@report))
  end

  def test_complete_export_decodes_and_existing_output_is_preserved
    persist
    result = TTSChapterFinalize.run(@root)
    assert_equal 0, result.fetch("validation_exit_code")
    assert_equal 2, result.fetch("blocks")
    assert_operator result.fetch("audio_duration_s"), :>, 0.5
    hash = TTSBookBenchmark.sha(File.join(@root, "chapter.mp3"))
    assert_raises(ArgumentError) { TTSChapterFinalize.run(@root) }
    assert_equal hash, TTSBookBenchmark.sha(File.join(@root, "chapter.mp3"))
  end

  def test_reordered_missing_or_failed_blocks_never_export
    @report["runs"].reverse!
    persist
    assert_raises(ArgumentError) { TTSChapterFinalize.run(@root) }
    @report["runs"].reverse!
    @report["runs"].first["status"] = "failed"
    persist
    assert_raises(ArgumentError) { TTSChapterFinalize.run(@root) }
    refute File.exist?(File.join(@root, "chapter.mp3"))
  end

  def test_modified_audio_is_rejected_before_export
    File.write(@report.fetch("runs").first.fetch("audio"), "changed")
    persist
    assert_raises(ArgumentError) { TTSChapterFinalize.run(@root) }
    refute File.exist?(File.join(@root, "chapter.mp3"))
  end
end
