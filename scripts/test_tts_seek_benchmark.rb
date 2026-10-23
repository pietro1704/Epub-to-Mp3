# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "tts_seek_benchmark"

class TTSSeekBenchmarkTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("seek benchmark ")
    @tone = File.join(@root, "tone.mp3")
    assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", @tone)
    @worker = File.join(@root, "worker.rb")
    File.write(@worker, <<~RUBY)
      require "fileutils"
      text, tone, output = ARGV
      File.write(output + ".pid", Process.pid.to_s)
      sleep 20 if text.start_with?("old")
      exit 7 if text.include?("failure")
      FileUtils.cp(tone, output)
    RUBY
    @manifest = {
      "deployment" => "remote", "samples" => 6.times.map do |index|
        text = "#{index < 3 ? 'old' : 'new'}-#{index}"
        { "id" => "chunk-#{index}", "text" => text, "offset" => index * 100, "sha256" => Digest::SHA256.hexdigest(text), "language" => "pt-BR", "source" => "test fixture" }
      end,
      "engines" => [{ "id" => "fixture", "voice" => "none", "model" => "test", "output_extension" => "mp3", "languages" => ["pt-BR"],
        "argv" => [RbConfig.ruby, @worker, "{text}", @tone, "{output}"],
        "assets" => [RbConfig.ruby, @worker, @tone].map { |path| { "path" => path, "sha256" => TTSBookBenchmark.sha(path) } } }]
    }
    @path = File.join(@root, "manifest.json")
    @output = File.join(@root, "results")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def execute
    File.write(@path, JSON.generate(@manifest))
    capture_io { @code = TTSSeekBenchmark.run(@path, @output, cancel_after: 0.1) }
    JSON.parse(File.read(File.join(@output, "report.json")))
  end

  def test_old_job_is_reaped_and_new_target_has_exact_identity
    report = execute
    assert_equal 0, @code
    assert_equal "passed", report.fetch("status")
    assert_equal 130, report.fetch("old_exit_code")
    assert_equal 2, report.fetch("old_unstarted")
    assert_equal 300, report.fetch("target_offset")
    assert report.fetch("new_sample_identities_match")
    assert_equal ["cancelled"], report.fetch("old_statuses")
    # Cancellation can win before the interpreter opens its marker file.
    Dir.glob(File.join(@output, "old/*.pid")).each do |marker|
      assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(marker))) }
    end
    target = JSON.parse(File.read(File.join(@output, "new/report.json")))
    assert_equal %w[chunk-3 chunk-4], target.fetch("runs").map { |row| row.fetch("sample") }
  end

  def test_failed_new_target_never_reports_a_successful_seek
    sample = @manifest.fetch("samples")[3]
    sample["text"] = "new-failure"
    sample["sha256"] = Digest::SHA256.hexdigest(sample.fetch("text"))
    report = execute
    assert_equal 1, @code
    assert_equal "failed", report.fetch("status")
  end

  def test_modified_input_is_rejected_before_process_or_output_creation
    @manifest.fetch("samples").first["text"] = "modified"
    File.write(@path, JSON.generate(@manifest))
    assert_raises(ArgumentError) { TTSSeekBenchmark.run(@path, @output) }
    refute File.exist?(@output)
  end
end
