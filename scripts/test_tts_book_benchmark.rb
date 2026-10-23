# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "tts_book_benchmark"

class TTSBookBenchmarkTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("tts book test ")
    @script = File.join(@directory, "voice fixture.rb")
    # A real, decoded audio fixture tests artifact validation independently of
    # any model implementation. It is not a speech-quality test.
    File.write(@script, <<~RUBY)
      require "fileutils"
      case ARGV.shift
      when "ok"
        source, output = ARGV.shift, ARGV.shift
        FileUtils.cp(source, output)
        File.write(output + ".input", ARGV.shift) unless ARGV.empty?
      when "fail"
        exit 7
      when "sleep"
        File.write(ARGV.shift, Process.pid.to_s)
        sleep 20
      end
    RUBY
    @wav = File.join(@directory, "fixture.wav")
    assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", @wav), "ffmpeg fixture setup"
    text = 'Literal $HOME `command` {output} text.'
    @manifest = {
      "samples" => [{ "id" => "sample", "text" => text, "sha256" => Digest::SHA256.hexdigest(text), "language" => "en", "source" => "test fixture" }],
      "engines" => [{ "id" => "fixture", "model" => "test-only-tone", "voice" => "none", "languages" => ["en"],
                      "argv" => [RbConfig.ruby, @script, "ok", @wav, "{output}"],
                      "assets" => [RbConfig.ruby, @script, @wav].map { |path| { "path" => path, "sha256" => TTSBookBenchmark.sha(path) } } }]
    }
    @manifest_path = File.join(@directory, "manifest.json")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def save_manifest
    File.write(@manifest_path, JSON.generate(@manifest))
  end

  def run_benchmark(execute: true, timeout: 2.0)
    save_manifest
    capture_io do
      @code = TTSBookBenchmark.run(@manifest_path, File.join(@directory, "results"), iterations: 1, timeout: timeout, execute: execute, lock_path: File.join(@directory, "lease"))
    end
    @code
  end

  def report
    JSON.parse(File.read(File.join(@directory, "results/report.json")))
  end

  def test_dry_run_has_no_output_or_child
    assert_equal 0, run_benchmark(execute: false)
    refute File.exist?(File.join(@directory, "results"))
  end

  def test_decoded_audio_and_identity_reach_report_and_csv
    assert_equal 0, run_benchmark
    row = report.fetch("runs").fetch(0)
    assert_equal "validated", row.fetch("status")
    assert_equal "fixture-sample-1", row.fetch("id")
    assert_equal TTSBookBenchmark.sha(@wav), row.fetch("audio_sha256")
    assert_in_delta 0.2, row.fetch("audio_duration_s"), 0.001
    assert_operator row.fetch("rtf"), :>, 0
    assert_equal @manifest.fetch("samples").first.fetch("text"), File.read(File.join(@directory, "results/sample.txt"))
    assert_equal row.fetch("id"), CSV.read(File.join(@directory, "results/results.csv"), headers: true).first.fetch("id")
    html = File.read(File.join(@directory, "results/index.html"))
    assert_includes html, "Human listening quality: pending"
    assert_includes html, "1/1 terminal attempts"
    assert_includes html, "fixture-sample-1.wav"
    assert_includes File.read(File.join(@directory, "results/results.md")), "validated"
  end

  def test_failure_is_retained_and_other_attempts_continue
    engine = @manifest.fetch("engines").first
    failed = Marshal.load(Marshal.dump(engine))
    failed["id"] = "broken"
    failed["argv"] = [RbConfig.ruby, @script, "fail", "{output}"]
    @manifest["engines"].unshift(failed)
    assert_equal 1, run_benchmark
    assert_equal ["failed", "validated"], report.fetch("runs").map { |row| row.fetch("status") }
    assert_equal 7, report.fetch("runs").first.fetch("exit_code")
    assert_includes File.read(File.join(@directory, "results/index.html")), "failed"
  end

  def test_modified_asset_and_duplicate_identity_are_rejected_before_output
    File.write(@script, "exit 0")
    assert_raises(ArgumentError) { run_benchmark }
    refute File.exist?(File.join(@directory, "results"))
    @manifest["samples"] *= 2
    assert_raises(ArgumentError) { run_benchmark }
  end

  def test_timeout_reaps_owned_process_and_records_attempt
    marker = File.join(@directory, "child.pid")
    @manifest.fetch("engines").first["argv"] = [RbConfig.ruby, @script, "sleep", marker, "{output}"]
    assert_equal 1, run_benchmark(timeout: 0.3)
    assert_equal "timeout", report.fetch("runs").first.fetch("status")
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(marker))) }
  end

  def test_lease_conflict_prevents_child_and_output
    File.open(File.join(@directory, "lease"), "w") do |lease|
      assert lease.flock(File::LOCK_EX | File::LOCK_NB)
      assert_raises(ArgumentError) { run_benchmark }
      refute File.exist?(File.join(@directory, "results"))
    end
  end

  def test_derived_attempt_identity_collision_is_rejected_before_output
    # Distinct individual IDs can concatenate to the same artifact name.
    sample = @manifest.fetch("samples").first
    sample["id"] = "b-c"
    @manifest.fetch("samples") << sample.merge("id" => "c")
    engine = @manifest.fetch("engines").first
    engine["id"] = "a"
    @manifest.fetch("engines") << engine.merge("id" => "a-b")
    assert_raises(ArgumentError) { run_benchmark }
    refute File.exist?(File.join(@directory, "results"))
  end

  def test_text_substitution_does_not_expand_shell_or_nested_placeholders
    @manifest.fetch("engines").first.fetch("argv") << "{text}"
    assert_equal 0, run_benchmark
    row = report.fetch("runs").first
    assert_equal @manifest.fetch("samples").first.fetch("text"), File.read(row.fetch("audio") + ".input")
  end

  def test_existing_output_and_modified_book_are_preserved_and_rejected
    assert_equal 0, run_benchmark
    original = File.binread(File.join(@directory, "results/report.json"))
    assert_raises(ArgumentError) { run_benchmark }
    assert_equal original, File.binread(File.join(@directory, "results/report.json"))
    @manifest["books"] = [{ "path" => @wav, "sha256" => "0" * 64 }]
    assert_raises(ArgumentError) { run_benchmark(execute: false) }
  end

  def test_silent_file_is_not_a_successful_synthesis
    silent = File.join(@directory, "silence.wav")
    assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", "0.2", silent)
    engine = @manifest.fetch("engines").first
    engine["argv"][3] = silent
    engine.fetch("assets") << { "path" => silent, "sha256" => TTSBookBenchmark.sha(silent) }
    assert_equal 1, run_benchmark
    row = report.fetch("runs").first
    assert_equal "failed", row.fetch("status")
    assert_match(/silent/, row.fetch("error"))
    refute row.key?("rtf")
  end

  def test_ctrl_c_records_cancellation_reaps_child_and_skips_next_attempt
    marker = File.join(@directory, "child.pid")
    @manifest.fetch("engines").first["argv"] = [RbConfig.ruby, @script, "sleep", marker, "{output}"]
    pending_marker = File.join(@directory, "must-not-start.pid")
    pending = @manifest.fetch("engines").first.merge("id" => "pending", "argv" => [RbConfig.ruby, @script, "sleep", pending_marker, "{output}"])
    @manifest.fetch("engines") << pending
    save_manifest
    # Exercise the real supervisor in a subprocess using a test-owned lease,
    # independently of an unrelated model benchmark/native job on this host.
    driver = "require ARGV.shift; exit TTSBookBenchmark.run(ARGV[0], ARGV[1], iterations: 1, timeout: 10.0, execute: true, lock_path: ARGV[2])"
    pid = Process.spawn(RbConfig.ruby, "-e", driver, File.join(__dir__, "tts_book_benchmark.rb"), @manifest_path, File.join(@directory, "results"), File.join(@directory, "lease"), out: File::NULL, err: File::NULL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(marker)
      raise "fixture did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    Process.kill("INT", pid)
    _, status = Process.waitpid2(pid)
    pid = nil
    assert_equal 130, status.exitstatus
    assert_equal ["cancelled"], report.fetch("runs").map { |row| row.fetch("status") }
    refute File.exist?(pending_marker)
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(marker))) }
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end
end
