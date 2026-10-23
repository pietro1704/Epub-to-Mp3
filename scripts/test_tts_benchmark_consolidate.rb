# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "tts_benchmark_consolidate"

class TTSBenchmarkConsolidateTest < Minitest::Test
  def test_buffer_replay_removes_startup_gap_without_changing_measured_trace
    rows = [
      { "status" => "validated", "started_batch_s" => 0.0, "command_wall_s" => 2.0, "audio_duration_s" => 2.0 },
      { "status" => "validated", "started_batch_s" => 2.0, "command_wall_s" => 4.0, "audio_duration_s" => 20.0 }
    ]
    baseline = Marshal.load(Marshal.dump(rows))
    immediate = TTSBenchmarkConsolidate.buffer_replay(rows, speed: 2.0, blocks: 1)
    buffered = TTSBenchmarkConsolidate.buffer_replay(rows, speed: 2.0, blocks: 2)
    assert_equal 3.0, immediate.fetch("stall_total_s")
    assert_equal 2.0, immediate.fetch("first_playback_s")
    assert_equal 0, buffered.fetch("stall_total_s")
    assert_equal 6.0, buffered.fetch("first_playback_s")
    assert_equal baseline, rows
    rows.first["status"] = "failed"
    assert_equal "incomplete", TTSBenchmarkConsolidate.buffer_replay(rows, speed: 2.0, blocks: 2).fetch("status")
  end

  def test_only_validated_outputs_contribute_to_median_and_private_text_is_excluded
    Dir.mktmpdir do |root|
      path = File.join(root, "evidence/run-01")
      FileUtils.mkdir_p(path)
      rows = [1.0, 3.0, 100.0].each_with_index.map do |duration, index|
        { "engine" => "fixture", "sample" => "passage", "status" => index < 2 ? "validated" : "failed",
          "command_wall_s" => duration, "audio_duration_s" => 10.0, "text" => "PRIVATE BOOK PASSAGE" }
      end
      File.write(File.join(path, "report.json"), JSON.generate({ "runs" => rows }))
      TTSBenchmarkConsolidate.run(root)
      note = File.read(File.join(root, "Benchmark-consolidado.md"))
      assert_includes note, "2/3 initial outputs validated"
      assert_includes note, "| fixture | passage | 2.00 | 10.00 |"
      refute_includes note, "PRIVATE BOOK PASSAGE"
      assert_includes note, "runtime acceptance remain pending"
      assert File.file?(File.join(root, "final.html"))
    end
  end

  def test_html_escapes_untrusted_provider_names_and_values
    html = TTSBenchmarkConsolidate.html([{ headers: ["<unsafe>"], rows: [["<script>alert(1)</script>"]] }], Dir.tmpdir)
    assert_includes html, "&lt;unsafe&gt;"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes html, "<script>"
  end

  def test_failed_whole_job_with_decodable_partial_audio_is_not_reported_as_complete
    Dir.mktmpdir do |root|
      directory = File.join(root, "chapter-whole-edge")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "report.json"), JSON.generate({ "runs" => [
        { "engine" => "edge-online-pt", "status" => "failed", "command_wall_s" => 90.75, "audio_duration_s" => 378.24 }
      ] }))
      TTSBenchmarkConsolidate.run(root)
      note = File.read(File.join(root, "Benchmark-consolidado.md"))
      assert_includes note, "| edge-online-pt | failed | 90.75 | unverified | unverified |"
      assert_includes note, "Observed command s"
    end
  end
end
