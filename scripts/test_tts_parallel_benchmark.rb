# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "tts_parallel_benchmark"

class TTSParallelBenchmarkTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("parallel tts ")
    @tone = File.join(@root, "fixture.wav")
    assert system("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", @tone)
    @worker = File.join(@root, "worker.rb")
    File.write(@worker, <<~RUBY)
      require "json"
      require "fileutils"
      mode, input, output = ARGV
      File.write(output + ".pid", Process.pid.to_s)
      if mode == "zero-exit-parent"
        Signal.trap("TERM") { exit 0 }
        Signal.trap("INT") { exit 0 }
        Process.spawn(RbConfig.ruby, "-e", 'Signal.trap("TERM", "IGNORE"); Signal.trap("INT", "IGNORE"); File.write(ARGV[0], Process.pid.to_s); sleep 20', output + ".desc.pid")
        sleep 20
      end
      if ["limit", "auth"].include?(mode)
        File.write(output + ".timing.json", JSON.generate({http_status:mode == "auth" ? 401 : 429}))
        exit 1
      end
      sleep(mode == "sleep" ? 20 : 0.2)
      FileUtils.cp(input, output)
    RUBY
    text = "Fixture text"
    @manifest = {
      "deployment" => "remote", "samples" => [{ "id" => "sample", "text" => text, "language" => "en", "source" => "test fixture", "sha256" => Digest::SHA256.hexdigest(text) }],
      "engines" => [{ "id" => "fixture", "languages" => ["en"], "model" => "test only", "voice" => "none",
                      "argv" => [RbConfig.ruby, @worker, "ok", @tone, "{output}"],
                      "assets" => [RbConfig.ruby, @worker, @tone].map { |p| { "path" => p, "sha256" => TTSBookBenchmark.sha(p) } } }]
    }
    @manifest_path = File.join(@root, "manifest.json")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_batch(concurrency: 2, iterations: 2, timeout: 3.0)
    File.write(@manifest_path, JSON.generate(@manifest))
    capture_io do
      @code = TTSParallelBenchmark.run(@manifest_path, File.join(@root, "results"), concurrency: concurrency, iterations: iterations, timeout: timeout, remote: true)
    end
    @code
  end

  def report
    JSON.parse(File.read(File.join(@root, "results/report.json")))
  end

  def test_actual_workers_overlap_and_artifact_identities_remain_distinct
    assert_equal 0, run_batch
    result = report
    assert_equal 2, result.fetch("peak_active_clients")
    assert_equal %w[validated validated], result.fetch("runs").map { |r| r.fetch("status") }
    assert_equal 2, result.fetch("runs").map { |r| r.fetch("audio") }.uniq.length
    assert_operator result.fetch("generation_batch_wall_s"), :<, result.fetch("runs").sum { |r| r.fetch("command_wall_s") }
    result.fetch("runs").each { |r| assert_equal TTSBookBenchmark.sha(@tone), r.fetch("audio_sha256") }
  end

  def test_rate_limit_prevents_pending_requests_without_retry
    @manifest.fetch("engines").first.fetch("argv")[2] = "limit"
    assert_equal 1, run_batch(concurrency: 1, iterations: 3)
    assert_equal 1, report.fetch("runs").length
    assert_equal 2, report.fetch("unstarted_attempts")
    assert_equal "provider_limit_or_refusal", report.fetch("halt_reason")
  end

  def test_deadline_reaps_owned_workers
    @manifest.fetch("engines").first.fetch("argv")[2] = "sleep"
    assert_equal 1, run_batch(timeout: 0.4)
    assert_equal %w[timeout timeout], report.fetch("runs").map { |r| r.fetch("status") }
    report.fetch("runs").each do |row|
      pid = Integer(File.read(row.fetch("audio") + ".pid"))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_authentication_refusal_does_not_trigger_pending_requests
    @manifest.fetch("engines").first.fetch("argv")[2] = "auth"
    assert_equal 1, run_batch(concurrency: 1, iterations: 3)
    assert_equal 1, report.fetch("runs").length
    assert_equal 2, report.fetch("unstarted_attempts")
  end

  def test_timeout_reaps_descendants_even_when_parent_exits_successfully
    @manifest.fetch("engines").first.fetch("argv")[2] = "zero-exit-parent"
    assert_equal 1, run_batch(concurrency: 1, iterations: 1, timeout: 1.0)
    marker = report.fetch("runs").first.fetch("audio") + ".desc.pid"
    descendant = Integer(File.read(marker))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    alive = true
    while alive && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        Process.kill(0, descendant)
        sleep 0.01
      rescue Errno::ESRCH
        alive = false
      end
    end
    refute alive, "timed-out zero-exit parent left a live descendant"
  ensure
    Process.kill("KILL", descendant) rescue Errno::ESRCH if descendant
  end

  def test_local_load_honours_the_shared_lease_and_two_worker_cap
    @manifest["deployment"] = "local"
    File.write(@manifest_path, JSON.generate(@manifest))
    output = File.join(@root, "results")
    lease_path = File.join(@root, "lease")
    assert_raises(ArgumentError) { TTSParallelBenchmark.run(@manifest_path, output, concurrency: 3, timeout: 1.0, remote: false, lock_path: lease_path) }
    File.open(lease_path, "w") do |lease|
      lease.flock(File::LOCK_EX)
      assert_raises(ArgumentError) { TTSParallelBenchmark.run(@manifest_path, output, concurrency: 2, timeout: 1.0, remote: false, lock_path: lease_path) }
    end
    refute File.exist?(output)
  end

  def test_cancellation_reaps_zero_exit_parent_and_its_descendant
    @manifest.fetch("engines").first.fetch("argv")[2] = "zero-exit-parent"
    File.write(@manifest_path, JSON.generate(@manifest))
    pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "tts_parallel_benchmark.rb"), "--manifest", @manifest_path, "--output", File.join(@root, "results"), "--remote", "--concurrency", "1", "--iterations", "3", out: File::NULL, err: File::NULL)
    marker = File.join(@root, "results/fixture-sample-1.wav.desc.pid")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(marker)
      raise "descendant did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    descendant = Integer(File.read(marker))
    Process.kill("INT", pid)
    _, status = Process.waitpid2(pid)
    pid = nil
    assert_equal 130, status.exitstatus
    assert_equal 2, report.fetch("unstarted_attempts")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    alive = true
    while alive && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      begin
        Process.kill(0, descendant)
        sleep 0.01
      rescue Errno::ESRCH
        alive = false
      end
    end
    refute alive, "cancelled zero-exit parent left a live descendant"
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    Process.kill("KILL", descendant) rescue Errno::ESRCH if descendant
  end

  def test_process_cancellation_reaps_active_and_never_starts_pending_workers
    @manifest.fetch("engines").first.fetch("argv")[2] = "sleep"
    File.write(@manifest_path, JSON.generate(@manifest))
    pid = Process.spawn(RbConfig.ruby, File.join(__dir__, "tts_parallel_benchmark.rb"), "--manifest", @manifest_path, "--output", File.join(@root, "results"), "--remote", "--concurrency", "1", "--iterations", "3", out: File::NULL, err: File::NULL)
    marker = File.join(@root, "results/fixture-sample-1.wav.pid")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(marker)
      raise "fixture did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    Process.kill("INT", pid)
    _, status = Process.waitpid2(pid)
    pid = nil
    assert_equal 130, status.exitstatus
    assert_equal ["cancelled"], report.fetch("runs").map { |r| r.fetch("status") }
    assert_equal 2, report.fetch("unstarted_attempts")
    assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(marker))) }
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end
end
