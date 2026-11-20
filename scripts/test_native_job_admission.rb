# frozen_string_literal: true
require "minitest/autorun"
require_relative "native_job_host_fixture"

# Admission, waiting, priority and the flight recorder of the real supervisor,
# on a fixture lease with fixture telemetry.
class NativeJobAdmissionTest < Minitest::Test
  include NativeJobHostFixture

  def test_loaded_host_refuses_before_any_child_and_releases_the_lease
    samples(LOADED)
    %w[build heavy].each do |phase|
      _, error, status = job(phase: phase)
      assert_equal 75, status.exitstatus, error
      assert_match(/Heavy job refused.*load average 7\.12 exceeds 6\.00.*CPU_Speed_Limit is 81/, error)
      assert_match(/a wait is expected: the default is 0 s, and --wait SECONDS or EPUB_NATIVE_WAIT_SECONDS sets another \(0 refuses at once\)/, error)
      refute File.exist?(@marker), phase
      refute Dir.exist?(@flight), "a refused job records nothing"
      assert_released
    end
  end

  def test_swap_and_compressor_left_by_earlier_work_warn_and_never_refuse
    flight_log = File.join(@flight, "flight.jsonl")
    samples(OLD_SWAP)
    _, error, status = job(phase: "heavy")
    assert status.success?, "1193 MiB of swap on an idle host with normal memory pressure refused the job: #{error}"
    refute_match(/warning/, error, "a reading inside the measured range is not worth a line")
    File.delete(@marker)
    samples(HEAVY_HISTORY)
    go = File.join(@dir, "go")
    pid, log = background_job(child: [RUBY, "-e", "#{until_file(0)}; File.write(ARGV[1], 'ran')", go, @marker])
    wait_until { File.exist?(flight_log) && File.read(flight_log).include?('"swap_used_mib":6144.0') }
    File.write(go, "")
    assert exit_status(pid).success?, "sizes that record earlier pressure refused the job: #{File.read(log)}"
    assert_equal ["native_job: warning, not a refusal: swap in use 6144 MiB is above 1600 MiB; " \
                  "memory compressor occupies 57% of memory, above 25%. The flight log records it."],
                 File.readlines(log, chomp: true).grep(/warning/)
    recorded = File.readlines(flight_log, chomp: true).map { |line| JSON.parse(line) }.find { |line| line["swap_used_mib"] == 6144.0 }
    assert_equal [4669, ["swap in use 6144 MiB is above 1600 MiB", "memory compressor occupies 57% of memory, above 25%"]],
                 recorded.values_at("compressor_mib", "warnings")
    assert_equal "ran", File.read(@marker)
    File.delete(@marker)

    # Present stress on that same host still refuses, and says nothing about the sizes.
    { { "pressure" => 2 } => /memory pressure is warning/, { "cpu_speed_limit" => 81 } => /CPU_Speed_Limit is 81/,
      { "load" => [7.12, 4.46, 8.85] } => /1-minute load average 7\.12 exceeds 6\.00/,
      { "compilers" => ["cargo 61001"] } => /a compiler is already running \(cargo 61001\)/ }.each do |change, expected|
      samples(HEAVY_HISTORY.merge(change))
      _, error, status = job
      assert_equal 75, status.exitstatus, "#{change}: #{error}"
      assert_match(/Heavy job refused\. The host is already loaded: #{expected.source}/, error, change.inspect)
      refute_match(/swap|compressor|;/, error, "one reason, and never a size that records history: #{change.inspect}")

      refute File.exist?(@marker), change.inspect
    end
    assert_released
  end

  def test_a_package_manager_or_ide_compile_outside_the_lease_is_refused_and_can_be_waited_for
    samples(FOREIGN_BUILD)
    _, error, status = job(phase: "heavy")
    assert_equal 75, status.exitstatus, error
    assert_match(/Heavy job refused.*a compiler is already running \(cargo 61001, rustc 61020\)/, error)
    refute File.exist?(@marker)
    samples(FOREIGN_BUILD, IDLE)
    _, error, status = job("--wait", "60")
    assert status.success?, error
    assert_equal 1, error.scan("Rechecking in 1 s").length, error
    assert File.exist?(@marker)
    assert_released
  end

  def test_wait_keeps_the_lease_until_the_host_is_admitted
    samples(LOADED, LOADED, IDLE)
    _, error, status = job
    assert_equal 75, status.exitstatus, "without a wait the first refusal is final: #{error}"
    samples(LOADED, LOADED, IDLE)
    _, error, status = job("--wait", "60")
    assert status.success?, error
    assert_equal 2, error.scan("Rechecking in 1 s, waiting up to 60 s in all.").length, error
    assert_equal "running", JSON.parse(File.read(@marker))["state"]
    File.delete(@marker)
    samples(LOADED)
    _, error, status = job(phase: "heavy", env: { NativeJob::WAIT_ENV => "2" })
    assert_equal 75, status.exitstatus, error
    assert_match(/not started yet\. The host is already loaded: .* Rechecking/, error)
    assert_match(/Heavy job refused\. The host is already loaded: .* Still so after waiting \d+ s\./, error)
    refute File.exist?(@marker)
    assert_released
  end

  def test_a_job_right_after_another_waits_for_the_host_to_settle_by_default
    settling = limits("default_wait_seconds" => 60)
    samples(LOADED, LOADED, IDLE)
    _, error, status = job(env: settling)
    assert status.success?, "load left by the previous job refused the next one at once: #{error}"
    assert_equal 2, error.scan("Rechecking in 1 s, waiting up to 60 s in all (the default).").length, error
    File.delete(@marker)
    [{ arguments: ["--wait", "0"] }, { env: { NativeJob::WAIT_ENV => "0" } }].each do |form|
      samples(LOADED, IDLE)
      _, error, status = job(*form.fetch(:arguments, []), env: settling.merge(form.fetch(:env, {})))
      assert_equal 75, status.exitstatus, "an explicit 0 refuses at once: #{error}"
      refute_match(/Rechecking/, error)
    end
    samples(LOADED)
    _, error, status = job(env: limits("default_wait_seconds" => 2))
    assert_equal 75, status.exitstatus, "sustained overload is still refused: #{error}"
    assert_match(/Heavy job refused\. .* Still so after waiting \d+ s\. .* the default is 2 s/, error)
    refute File.exist?(@marker)
    assert_released
  end

  def test_a_wait_that_is_not_whole_seconds_fails_instead_of_meaning_no_wait
    samples(LOADED)
    ["15m", "900s", " 900", "-5", "1.5"].each do |value|
      [{ env: { NativeJob::WAIT_ENV => value } }, { arguments: ["--wait", value] }].each do |form|
        _, error, status = job(*form.fetch(:arguments, []), env: form.fetch(:env, {}))
        assert_equal 75, status.exitstatus, "#{form}: #{error}"
        assert_match(/Invalid wait #{Regexp.escape(value.inspect)}: give whole seconds/, error, form.inspect)
        refute_match(/Heavy job refused/, error, "an invalid wait is reported before any admission reading")
        refute File.exist?(@lock), "nothing was acquired"
      end
    end
  end

  def test_a_wait_shorter_than_the_retry_interval_still_retries_at_its_end
    slow_retry = limits("recheck_seconds" => 600).merge("FIXTURE_LEASE_RETRY" => "600")
    samples(LOADED, IDLE)
    _, error, status = job("--wait", "6", env: slow_retry)
    assert status.success?, "the one recheck happens when the wait ends, not after the 600 s interval: #{error}"
    assert_match(/Rechecking in [1-6] s/, error)
    File.delete(@marker)
    samples(IDLE)
    holding do |_, _, release|
      waiter, log = background_job("--wait", "10", env: slow_retry)
      wait_until { said?(log, "retrying in") }
      release.call
      assert exit_status(waiter).success?, File.read(log)
      refute_match(/retrying in 600 s/, File.read(log))
    end
    assert_released
  end

  def test_child_starts_at_the_lower_priority_whatever_priority_this_suite_runs_at
    target = LIMITS.fetch("child_niceness")
    probe = [RUBY, "-e", "File.write(ARGV[0], Process.getpriority(Process::PRIO_PROCESS, 0))", @marker]
    reader = [RUBY, "-e", "print Process.getpriority(Process::PRIO_PROCESS, 0)"]
    # Inside the heavy host-suite job this suite is itself niced. The extra steps
    # put the supervisor below, at and above the target whatever it started from.
    [0, 4, 15].each do |extra|
      lower = extra.zero? ? [] : ["/usr/bin/nice", "-n", extra.to_s]
      supervisor_priority = Integer(Open3.capture2(*lower, *reader).first)
      [nil, File.join(@dir, "missing-nice")].each do |nice|
        _, error, status = job(child: probe, env: { "FIXTURE_NICE" => nice }, prefix: lower)
        assert status.success?, error
        needs_lowering = supervisor_priority < target
        expected = needs_lowering && nice.nil? ? target : supervisor_priority
        assert_equal expected, Integer(File.read(@marker)), "supervisor at #{supervisor_priority}, nice #{nice.inspect}"
        if needs_lowering && nice
          assert_match(/missing-nice is unavailable; this job runs at normal priority/, error)
        else
          refute_match(/unavailable/, error, "a job that needs no lowering reports nothing (supervisor at #{supervisor_priority})")
        end
      end
    end
    _, error, status = job(child: ["no-such-program-#{Process.pid}"])
    assert_equal 75, status.exitstatus, "a missing program is the supervisor's refusal, not the wrapper's: #{error}"
    assert_released
  end

  def test_flight_recorder_writes_only_while_the_job_runs
    go = File.join(@dir, "go")
    flight_log = File.join(@flight, "flight.jsonl")
    child = [RUBY, "-e", "#{until_file(0)}; exit 17", go]
    pid, log = background_job(child: child)
    wait_until { File.exist?(flight_log) && File.read(flight_log).scan('"event":"sample"').length >= 2 }
    File.write(go, "")
    assert_equal 17, exit_status(pid).exitstatus, File.read(log)
    events = File.readlines(flight_log, chomp: true).map { |line| JSON.parse(line) }
    kinds = events.map { |event| event["event"] }
    assert_equal %w[start end], [kinds.first, kinds.last]
    assert_empty kinds - %w[start sample end]
    assert_equal 17, events.last["exit_status"]
    assert_equal "4f00000000000000", events.first["startup_power_events"]
    events.each { |event| assert_equal ["build", PROGRAM], event["holder"].values_at("phase", "program") }
    events[0..-2].each do |event|
      assert_equal IDLE["load"], event["load"]
      assert_equal ["98.2 47168 swift-frontend"], event["top"]
      assert_equal [], event["warnings"]
    end
    assert_released
  end

  def test_slow_telemetry_never_delays_cancellation
    holding(env: { "FIXTURE_FAST_SAMPLES" => "1", "FIXTURE_SAMPLE_DELAY" => "120" }) do |supervisor, child|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", supervisor)
      status = exit_status(supervisor)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal 143, status.exitstatus
      assert_operator elapsed, :<, 60, "the supervisor waited for a 120 s probe before it forwarded the signal"
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
    end
    assert_released
    events = File.readlines(File.join(@flight, "flight.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    assert_equal [143], events.select { |event| event["event"] == "end" }.map { |event| event["exit_status"] }
  end

  def test_heavy_phase_skips_only_the_compiler_preflight
    child = [RUBY, "-e", "File.write(ARGV[0], ENV.fetch('CARGO_BUILD_JOBS'))", @marker]
    _, error, status = job(phase: "heavy", child: child, env: { "FAKE_STATE" => "Booted" })
    assert status.success?, error
    assert_equal "1", File.read(@marker)
    if RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
      File.delete(@marker)
      _, error, status = job(child: child, env: { "FAKE_STATE" => "Booted" })
      assert_equal 75, status.exitstatus, error
      assert_match(/Shut down all Simulators/, error)
      refute File.exist?(@marker)
    end
    assert_released
  end

  def test_host_services_belong_to_the_real_host_lease_only
    assert_equal NativeJob::HOST_LEASE, File.expand_path(NativeJob::LOCK_PATH)
    assert_equal !NativeJob.hosted_runner?, NativeJob.host_services?(NativeJob::LOCK_PATH, host: "x86_64-darwin24")
    refute NativeJob.host_services?(NativeJob::LOCK_PATH, host: "x86_64-linux")
    refute NativeJob.host_services?(@lock, host: "x86_64-darwin24"), "a fixture lease never reads host load"
    refute NativeJob.host_services?("/var/tmp/epub2mp3.heavy-job.lock", host: "x86_64-darwin24")
    refute Object.const_defined?(:HostLoad), "host modules load only for the host lease"
  end
end
