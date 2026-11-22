# frozen_string_literal: true
require "minitest/autorun"
require_relative "native_job_host_fixture"

# Advisory host notes, priority and the flight recorder of the real supervisor,
# on a fixture lease with fixture telemetry. No reading refuses, delays or stops a job.
class NativeJobHostNotesTest < Minitest::Test
  include NativeJobHostFixture

  def test_a_loaded_host_is_noted_and_never_refuses_or_waits
    samples(LOADED)
    %w[build heavy].each do |phase|
      _, error, status = job(phase: phase)
      assert status.success?, "#{phase}: a loaded host refused the job: #{error}"
      assert_match(/advisory, not a refusal: .*load average 7\.12 exceeds 6\.00.*CPU_Speed_Limit is 81/, error)
      refute_match(/refused|Rechecking|waiting/, error, phase)
      assert_equal "running", JSON.parse(File.read(@marker))["state"], phase
      File.delete(@marker)
      assert_released
    end
  end

  def test_every_former_refusal_reading_is_only_a_note
    notes = { { "pressure" => 2 } => /memory pressure is warning/, { "cpu_speed_limit" => 81 } => /CPU_Speed_Limit is 81/,
              { "cpu_available" => 6 } => /only 6 of 8 CPUs available/,
              { "load" => [7.12, 4.46, 8.85] } => /1-minute load average 7\.12 exceeds 6\.00/,
              { "compilers" => ["cargo 61001", "rustc 61020"] } => /a compiler is already running \(cargo 61001, rustc 61020\)/,
              { "swap_used_mib" => 6144.0, "compressor_mib" => 4669 } => /swap in use 6144 MiB is above 1600 MiB; memory compressor occupies 57%/ }
    notes.each do |change, expected|
      samples(IDLE.merge(change))
      _, error, status = job(phase: "heavy")
      assert status.success?, "#{change}: #{error}"
      assert_match(expected, error, change.inspect)
      assert File.exist?(@marker), change.inspect
      File.delete(@marker)
    end
    assert_released
  end

  def test_an_idle_host_and_old_swap_inside_the_measured_range_say_nothing
    [IDLE, OLD_SWAP].each do |reading|
      samples(reading)
      _, error, status = job(phase: "heavy")
      assert status.success?, error
      refute_match(/advisory/, error)
      File.delete(@marker)
    end
  end

  def test_notes_reach_the_flight_log_while_the_job_runs
    flight_log = File.join(@flight, "flight.jsonl")
    samples(HEAVY_HISTORY)
    go = File.join(@dir, "go")
    pid, log = background_job(child: [RUBY, "-e", "#{until_file(0)}; File.write(ARGV[1], 'ran')", go, @marker])
    wait_until { File.exist?(flight_log) && File.read(flight_log).include?('"swap_used_mib":6144.0') }
    File.write(go, "")
    assert exit_status(pid).success?, File.read(log)
    assert_equal ["native_job: advisory, not a refusal: swap in use 6144 MiB is above 1600 MiB; " \
                  "memory compressor occupies 57% of memory, above 25%. The flight log records it."],
                 File.readlines(log, chomp: true).grep(/advisory/)
    recorded = File.readlines(flight_log, chomp: true).map { |line| JSON.parse(line) }.find { |line| line["swap_used_mib"] == 6144.0 }
    assert_equal [4669, ["swap in use 6144 MiB is above 1600 MiB", "memory compressor occupies 57% of memory, above 25%"]],
                 recorded.values_at("compressor_mib", "warnings")
    assert_equal "ran", File.read(@marker)
    assert_released
  end

  def test_unreadable_host_telemetry_is_a_note_and_the_job_still_runs
    File.delete(@samples) if File.exist?(@samples)
    _, error, status = job(phase: "heavy")
    assert status.success?, error
    assert_match(/advisory, not a refusal: host load inspection failed/, error)
    assert File.exist?(@marker)
    assert_released
  end

  def test_the_wait_applies_to_the_lease_only
    holding do |_, _, release|
      _, error, status = job("--wait", "0")
      assert_equal 75, status.exitstatus, "a busy lease is still one lease: #{error}"
      assert_match(/Another native\/heavy job is active/, error)
      refute_match(/advisory/, error)
      release.call
    end
    ["15m", "900s", " 900", "-5", "1.5"].each do |value|
      [{ env: { NativeJob::WAIT_ENV => value } }, { arguments: ["--wait", value] }].each do |form|
        _, error, status = job(*form.fetch(:arguments, []), env: form.fetch(:env, {}))
        assert_equal 75, status.exitstatus, "#{form}: #{error}"
        assert_match(/Invalid wait #{Regexp.escape(value.inspect)}: give whole seconds/, error, form.inspect)
        refute File.exist?(@marker), "nothing ran"
      end
    end
  end

  def test_a_wait_shorter_than_the_retry_interval_still_retries_at_its_end
    slow_retry = { "FIXTURE_LEASE_RETRY" => "600" }
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

  def test_build_and_heavy_phases_both_run_one_job_by_default
    child = [RUBY, "-e", "File.write(ARGV[0], ENV.fetch('CARGO_BUILD_JOBS'))", @marker]
    %w[build heavy simulator].each do |phase|
      _, error, status = job(phase: phase, child: child)
      assert status.success?, "#{phase}: #{error}"
      assert_equal "1", File.read(@marker)
      File.delete(@marker)
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
