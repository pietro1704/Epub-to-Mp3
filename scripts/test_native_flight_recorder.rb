# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "timeout"
require_relative "native_flight_recorder"

class NativeFlightRecorderTest < Minitest::Test
  # A holder that still carries what a record must never store: arguments and absolute paths.
  HOLDER = { "pid" => 45_932, "phase" => "build", "state" => "running", "program" => "xcodebuild", "task" => "mac:test:local",
             "started" => "2026-11-20T01:08:37Z", "worktree" => "epubtomp3-pr-h", "session" => "claude=abc",
             "command" => "xcodebuild -authenticationKeyPath /Users/someone/AuthKey_SECRET123.p8", "cwd" => "/Users/someone/work" }.freeze
  RECORDED = %w[pid phase program task worktree session].freeze
  LIMITS = { "interval_seconds" => 30, "max_file_bytes" => 4096, "generations" => 2 }.freeze

  def setup
    @dir = Dir.mktmpdir("flight-recorder-")
    @samples = []
    @clock = Time.utc(2026, 11, 20, 1, 8, 37)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def recorder(directory: @dir, limits: LIMITS, sampler: -> { @samples.shift || { "load" => [1.0, 1.0, 1.0] } })
    NativeFlightRecorder::Recorder.new(holder: HOLDER, directory: directory, limits: limits, sampler: sampler,
                                       host: -> { { "boot" => "2026-11-20T00:36:22Z", "startup_power_events" => "4f00000000000000" } },
                                       wall: -> { @clock })
  end

  def lines(path = File.join(@dir, NativeFlightRecorder::FILE))
    File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
  end

  # Readings are taken on a probe thread; wait for the one in flight.
  def settle(flight)
    flight.instance_variable_get(:@worker)&.join(10)
  end

  def seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def test_records_start_one_sample_per_interval_and_end_with_the_holder
    @samples = [{ "load" => [7.12, 4.46, 8.85], "cpu_speed_limit" => 81, "top" => ["98.2 47168 swift-frontend"] },
                { "load" => [11.41, 7.35, 9.44], "swap_used_mib" => 1550.75 }, { "load" => [4.96, 7.53, 9.13] }]
    flight = recorder
    flight.tick(5.0)
    refute File.exist?(flight.path), "nothing is recorded before the job starts"
    flight.start(100.0)
    settle(flight)
    flight.tick(129.9)
    flight.tick(130.0)
    settle(flight)
    flight.tick(131.0)
    flight.finish(143)
    flight.tick(500.0)
    flight.finish(0)
    events = lines
    assert_equal %w[start sample end], events.map { |event| event["event"] }
    refute events[2].key?("load"), "the end line reads nothing from the host"
    assert_equal ["2026-11-20T01:08:37Z"], events.map { |event| event["t"] }.uniq
    events.each { |event| assert_equal HOLDER.slice(*RECORDED), event["holder"] }
    assert_equal "4f00000000000000", events[0]["startup_power_events"]
    assert_equal [7.12, 4.46, 8.85], events[0]["load"]
    assert_equal ["98.2 47168 swift-frontend"], events[0]["top"]
    assert_in_delta 1550.75, events[1]["swap_used_mib"]
    assert_equal 143, events[2]["exit_status"]
  end

  def test_lines_carry_no_argument_or_absolute_path_and_only_the_owner_can_read_them
    created = File.join(@dir, "evidence", "native-flight-recorder")
    flight = recorder(directory: created,
                      sampler: -> { { "load" => [1.0, 1.0, 1.0], "top" => ["9.0 1 xcodebuild"], "compilers" => ["xcodebuild 1"] } })
    flight.start(0.0)
    settle(flight)
    flight.tick(30.0)
    settle(flight)
    flight.finish(0)
    text = File.read(flight.path)
    ["SECRET123", "authenticationKey", "/Users/", "someone", @dir, Dir.home].each do |forbidden|
      refute_includes text, forbidden, "the flight log must not carry #{forbidden}"
    end
    assert_equal 3, lines(flight.path).length
    assert_equal %w[700 700 600], [File.dirname(created), created, flight.path].map { |path| format("%o", File.stat(path).mode & 0o777) },
                 "what the recorder creates is the owner's alone"
    loose = File.join(@dir, "loose")
    Dir.mkdir(loose, 0o755)
    File.write(File.join(loose, NativeFlightRecorder::FILE), "")
    File.chmod(0o644, File.join(loose, NativeFlightRecorder::FILE))
    flight = recorder(directory: loose)
    flight.start(0.0)
    settle(flight)
    assert_equal %w[755 600], [loose, flight.path].map { |path| format("%o", File.stat(path).mode & 0o777) },
                 "an existing file is tightened; a directory the recorder did not create is left as it is"
  end

  def test_finding_the_shared_directory_cannot_hang_on_git
    stalled = File.join(@dir, "bin")
    Dir.mkdir(stalled)
    File.write(File.join(stalled, "git"), "#!/bin/sh\nsleep 60\n")
    File.chmod(0o755, File.join(stalled, "git"))
    path = ENV.fetch("PATH")
    ENV["PATH"] = "#{stalled}:#{path}"
    elapsed = seconds { assert_equal File.join(NativeFlightRecorder::ROOT, ".reports", "native-flight-recorder"), NativeFlightRecorder.directory({}) }
    assert_operator elapsed, :<, 20, "the lookup must give up on a git that does not answer"
  ensure
    ENV["PATH"] = path if path
  end

  def test_a_reading_carries_the_notes_it_earns
    limits = { "warn_load_percent_of_cpus" => 75, "warn_swap_used_mib" => 1600, "warn_compressor_percent_of_memory" => 25 }
    quiet = { "load" => [2.0, 2.0, 2.0], "cpus" => 8, "pressure" => 1, "swap_used_mib" => 1192.75, "compressor_mib" => 368,
              "memory_mib" => 8192, "compilers" => [], "own_compilers" => [] }
    assert_equal quiet.merge("warnings" => []), NativeFlightRecorder.reading(sampler: -> { quiet }, policy: -> { limits })
    grown = quiet.merge("swap_used_mib" => 1700.0)
    assert_equal ["swap in use 1700 MiB is above 1600 MiB"],
                 NativeFlightRecorder.reading(sampler: -> { grown }, policy: -> { limits }).fetch("warnings")
    loaded = quiet.merge("load" => [7.12, 4.0, 3.0])
    assert_match(/load average 7\.12/, NativeFlightRecorder.reading(sampler: -> { loaded }, policy: -> { limits }).fetch("warnings").join)
    assert_equal %w[warn_load_percent_of_cpus warn_swap_used_mib], HostLoad.limits.keys.first(2), "the real policy names the advisory thresholds"
  end

  def test_rotation_bounds_storage_to_the_configured_generations

    path = File.join(@dir, "bounded.jsonl")
    40.times { |index| NativeFlightRecorder.append(path, { "n" => index, "pad" => "x" * 90 }, max_bytes: 512, generations: 2) }
    files = Dir.children(@dir).sort
    assert_equal %w[bounded.jsonl bounded.jsonl.1 bounded.jsonl.2], files
    files.each { |name| assert_operator File.size(File.join(@dir, name)), :<=, 512, name }
    files.each { |name| assert_equal "600", format("%o", File.stat(File.join(@dir, name)).mode & 0o777), name }
    assert_equal 39, lines(path).last["n"]
    kept = files.flat_map { |name| lines(File.join(@dir, name)).map { |record| record["n"] } }.sort
    assert_equal (kept.min..39).to_a, kept, "only the oldest records are dropped"
    assert_operator kept.min, :>, 0
  end

  def test_slow_telemetry_never_holds_the_supervisor_loop_or_the_exit_code
    reads = 0
    flight = recorder(sampler: -> { reads += 1; sleep 30; { "load" => [9.0, 9.0, 9.0] } })
    assert_operator seconds { flight.start(0.0) }, :<, 10, "start read the host on the supervisor loop"
    Timeout.timeout(20) { sleep 0.01 until reads == 1 }
    assert_operator seconds { flight.tick(30.0) }, :<, 10, "tick read the host on the supervisor loop"
    assert_operator seconds { flight.tick(60.0) }, :<, 10
    assert_equal 1, reads, "a probe that is still running is skipped, never queued"
    assert_operator seconds { flight.finish(143) }, :<, 10, "finish delayed the exit code"
    # Checked before any other work: a killed thread stays alive until joined.
    refute flight.instance_variable_get(:@worker).alive?, "no probe outlives the job"
    assert_equal [["end", 143]], lines.map { |event| event.values_at("event", "exit_status") }
  end

  def test_finish_waits_for_a_killed_probe_to_unwind
    reads = 0
    # A probe interrupted mid-read still runs its cleanup, as a closing pipe does.
    flight = recorder(sampler: lambda do
      reads += 1
      begin
        sleep 30
      ensure
        sleep 0.05
      end
    end)
    flight.start(0.0)
    Timeout.timeout(20) { sleep 0.01 until reads == 1 }
    flight.finish(0)
    refute flight.instance_variable_get(:@worker).alive?, "finish returned while the killed probe was still unwinding"
  end

  def test_sampling_and_storage_failures_never_raise_into_the_supervisor
    flight = recorder(sampler: -> { raise "telemetry lost" })
    flight.start(0.0)
    settle(flight)
    flight.finish(0)
    assert_equal ["RuntimeError: telemetry lost", nil], lines.map { |event| event["sample_error"] }
    assert_equal %w[start end], lines.map { |event| event["event"] }

    blocked = File.join(@dir, "not-a-directory")
    File.write(blocked, "")
    flight = recorder(directory: blocked)
    _, warnings = capture_io do
      flight.start(0.0)
      settle(flight)
      flight.tick(60.0)
      flight.finish(1)
    end
    assert_equal 1, warnings.scan("native flight recorder stopped").length, warnings
  end

  def test_directory_is_shared_by_linked_worktrees_and_can_be_redirected
    assert_equal File.expand_path("custom/flight"), NativeFlightRecorder.directory({ NativeFlightRecorder::DIRECTORY_ENV => "custom/flight" })
    shared = NativeFlightRecorder.directory({})
    assert_equal %w[.reports native-flight-recorder], shared.split(File::SEPARATOR).last(2)
    assert File.directory?(File.expand_path("../../.git", shared)), "the recorder belongs to the main checkout: #{shared}"
  end

  def test_host_reads_boot_power_events_and_the_newest_panic_report
    panic = File.join(@dir, "panic-full-2026-11-20-003504.0003.ips")
    File.write(panic, "{}")
    File.utime(Time.utc(2026, 11, 20, 0, 36, 33), Time.utc(2026, 11, 20, 0, 36, 33), panic)
    capture = lambda do |*argv, **|
      argv.include?("kern.boottime") ? "{ sec = 1795134982, usec = 639916 } Thu Nov 19 21:36:22 2026\n" : %(  "StartupPowerEvents" = <4f00000000000000>\n)
    end
    assert_equal({ "boot" => "2026-11-20T00:36:22Z", "startup_power_events" => "4f00000000000000",
                   "newest_panic_report" => "panic-full-2026-11-20-003504.0003.ips",
                   "newest_panic_report_time" => "2026-11-20T00:36:33Z" },
                 NativeFlightRecorder.host(capture: capture, reports: [File.join(@dir, "panic-full-*.ips")]))
    quiet = NativeFlightRecorder.host(capture: ->(*, **) { "" }, reports: [File.join(@dir, "none-*")])
    assert_equal [nil, nil, nil], quiet.values_at("boot", "startup_power_events", "newest_panic_report")
    assert_match(/RuntimeError: ioreg/, NativeFlightRecorder.host(capture: ->(*, **) { raise "ioreg" })["host_error"])
  end

  def test_limits_require_positive_integers
    assert_equal 30, NativeFlightRecorder.limits.fetch("interval_seconds"), "one line every 30 seconds"
    path = File.join(@dir, "policy.json")
    File.write(path, JSON.generate("flight_recorder" => LIMITS.merge("generations" => 0)))
    assert_match(/Invalid flight_recorder generations/, assert_raises(RuntimeError) { NativeFlightRecorder.limits(path) }.message)
    File.write(path, "{}")
    assert_match(/Missing flight_recorder/, assert_raises(RuntimeError) { NativeFlightRecorder.limits(path) }.message)
  end
end
