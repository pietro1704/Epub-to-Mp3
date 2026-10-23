# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "tts_chapter_benchmark"

class TTSChapterBenchmarkTest < Minitest::Test
  def row(start, wall, duration, status = "validated")
    { "started_batch_s" => start, "command_wall_s" => wall, "audio_duration_s" => duration, "status" => status }
  end

  def test_portuguese_chunks_preserve_all_text_offsets_and_sentence_boundaries
    text = ("Ação com \"aspas\", R$ 100 e inglês. Outra frase!\n\n" * 60) + "Fim."
    parts = TTSChapterBenchmark.chunks(text)
    assert_equal text, parts.map { |part| part.fetch("text") }.join
    assert_operator parts.first.fetch("text").length, :<=, 180
    parts.each do |part|
      assert_operator part.fetch("text").length, :<=, 480
      assert_equal part.fetch("text"), text[part.fetch("offset"), part.fetch("text").length]
      assert part.fetch("text").valid_encoding?
    end
    assert_equal "Fim.", parts.last.fetch("text").strip.split(/\s+/).last
  end

  def test_long_unpunctuated_text_is_bounded_without_character_loss
    text = "á" * 1201
    assert_equal text, TTSChapterBenchmark.chunks(text).map { |part| part.fetch("text") }.join
    assert_raises(ArgumentError) { TTSChapterBenchmark.chunks(" ") }
    assert_raises(ArgumentError) { TTSChapterBenchmark.chunks("Hello", maximum: 600) }
  end

  def test_out_of_order_completion_cannot_make_later_audio_play_early
    result = TTSChapterBenchmark.playback([row(0, 2, 3), row(0, 12, 4), row(2, 1, 2)])
    assert_equal 2, result.fetch("first_complete_mp3_s")
    assert_equal 1, result.fetch("stall_count")
    assert_equal 7, result.fetch("stall_total_s")
    assert_equal 18, result.fetch("playback_end_s")
  end

  def test_failed_or_cancelled_audio_never_counts_as_playable
    %w[failed timeout cancelled running].each do |status|
      assert_equal "incomplete", TTSChapterBenchmark.playback([row(0, 1, 2, status)]).fetch("status")
    end
    assert_equal "incomplete", TTSChapterBenchmark.playback([]).fetch("status")
    assert_raises(ArgumentError) { TTSChapterBenchmark.playback([], speed: 0.0) }
  end

  def test_prefetch_uses_playback_time_and_short_remaining_chapter_reports_gap
    current = TTSChapterBenchmark.playback([row(0, 2, 120)])
    following = TTSChapterBenchmark.playback([row(0, 3, 20)])
    assert_equal 62, TTSChapterBenchmark.prefetch(current, following).fetch("trigger_s")
    assert_equal 0, TTSChapterBenchmark.prefetch(current, following).fetch("predicted_boundary_gap_s")
    short = TTSChapterBenchmark.playback([row(0, 2, 1)])
    assert_equal 2, TTSChapterBenchmark.prefetch(short, following).fetch("predicted_boundary_gap_s")
    faster = TTSChapterBenchmark.playback([row(0, 2, 120)], speed: 2.0)
    assert_equal 2, TTSChapterBenchmark.prefetch(faster, following).fetch("trigger_s")
  end

  def test_source_identity_is_checked_before_creating_output
    Dir.mktmpdir do |directory|
      text = File.join(directory, "text.txt")
      File.write(text, "actual chapter")
      output = File.join(directory, "result")
      assert_raises(ArgumentError) do
        TTSChapterBenchmark.run(manifest_paths: [], text_path: text, expected_sha: "wrong", next_path: text, output: output)
      end
      refute File.exist?(output)
    end
  end

  def test_real_mp3_worker_preserves_quoted_unicode_text_and_separate_job_identity
    Dir.mktmpdir("chapter worker ") do |directory|
      tone = File.join(directory, "tone.wav")
      assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", tone)
      worker = File.join(directory, "generator.rb")
      File.write(worker, "require 'fileutils'; File.write(ARGV[2]+'.text', ARGV[0]); FileUtils.cp(ARGV[1], ARGV[2])")
      text = "Ação: \"aspas\"; $(echo unchanged) `literal` \\ caminho"
      text_path = File.join(directory, "input.txt")
      File.write(text_path, text)
      engine = { "id" => "fixture", "argv" => [RbConfig.ruby, worker, "{text}", tone, "{output}"], "assets" => [] }
      wrapped = TTSChapterBenchmark.mp3_engine(engine, directory)
      output = File.join(directory, "audio.mp3")
      argv = wrapped.fetch("argv").map { |argument| argument.gsub("{text_file}", text_path).gsub("{output}", output) }
      assert system(*argv, out: File::NULL)
      assert_equal text, File.read(output + ".source.wav.text")
      assert_equal 0, TTSBookBenchmark.inspect_audio(output, directory, 10).fetch("validation_exit_code")
      before = TTSBookBenchmark.sha(output)
      refute system(*argv, out: File::NULL, err: File::NULL)
      assert_equal before, TTSBookBenchmark.sha(output)
    end
  end
end
