# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "timeout"
require "stringio"

# The process contract runs only fake Ruby tools. No Apple service is queried.
class NativeSimulatorSessionTest < Minitest::Test
  SCRIPT = File.expand_path("native_simulator_session.rb", __dir__)
  RUBY = RbConfig.ruby
  UUID = "018637F5-CC86-449C-B071-D7D0C43FBEE0"

  class FakeBackend
    def initialize(directory, mode: "success")
      @directory = directory
      @mode = mode
    end

    def argv(phase, _plan)
      [RbConfig.ruby, File.join(@directory, "fake_tool.rb"), phase.to_s]
    end

    def environment(_phase, _plan)
      { "SESSION_FIXTURE" => @directory, "SESSION_MODE" => @mode }
    end
  end

  def setup
    @directory = Dir.mktmpdir("simulator-session-contract-")
    @lease = File.join(@directory, "heavy.lease")
    @report = File.join(@directory, "session.json")
    @plan_path = File.join(@directory, "plan.json")
    @marker = File.join(@directory, "operations.jsonl")
    host = File.join(@directory, "EpubToMp3.app", "EpubToMp3")
    FileUtils.mkdir_p(File.dirname(host))
    File.write(host, "owned test application executable")
    source = File.join(@directory, "source.swift")
    File.write(source, "source identity fixture")
    @tool = File.join(@directory, "fake_tool.rb")
    File.write(@tool, <<~'RUBY')
      require "json"
      require "fileutils"
      directory = ENV.fetch("SESSION_FIXTURE")
      phase = ARGV.fetch(0)
      mode = ENV.fetch("SESSION_MODE")
      require "socket" if mode == "cleanup_resource_deny"
      if phase == "monitor"
        puts JSON.generate("event" => "policy", "limits" => {
          "minimum_free_percent" => 20, "minimum_disk_bytes" => 8 * 1024**3,
          "maximum_swap_growth_bytes" => 256 * 1024**2,
          "maximum_sample_seconds" => 5.0, "query_timeout_seconds" => 2.0
        }, "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
           "duration_seconds" => 15.0, "interval_seconds" => 0.1)
        STDOUT.sync = true
        exit 0 if mode == "monitor_eof"
        acknowledged = false
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sample_started = mode == "old_collection_start" ? now - [100.0, now / 2].min : now
          denied = mode == "initial_resource_deny" ||
            (mode == "cleanup_resource_deny" && File.exist?(File.join(directory, "deny-requested")))
          panics = File.exist?(File.join(directory, "new-panic")) ? ["new-owned-panic-report"] : []
          puts JSON.generate("event" => "sample", "decision" => denied ? "deny" : "allow",
            "reasons" => denied ? ["available disk space below minimum"] : [],
            "sample" => { "started_monotonic" => sample_started, "collected_monotonic" => now,
              "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
              "logical_cpus" => 8, "memory_free_percent" => 58,
              "disk_free_bytes" => (denied ? 4 : 12) * 1024**3, "swap_used_bytes" => 0,
              "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => panics })
          STDOUT.flush
          if mode == "cleanup_resource_deny" && denied && !acknowledged
            UNIXSocket.open(File.join(directory, "deny.socket")) { |socket| socket.write("sample flushed") }
            acknowledged = true
          end
          sleep 0.03
        end
      end
      File.open(File.join(directory, "operations.jsonl"), "a") do |file|
        file.puts(JSON.generate("phase" => phase, "pid" => Process.pid,
                               "pgid" => Process.getpgrp))
      end
      case phase
      when "inspect"
        puts JSON.generate("device" => {
          "uuid" => "018637F5-CC86-449C-B071-D7D0C43FBEE0", "name" => "iPhone SE",
          "device_type" => "com.apple.CoreSimulator.SimDeviceType.iPhone-SE",
          "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-15-5", "state" => "Shutdown"
        }, "xcode_version" => "16.4")
      when "boot"
        File.write(File.join(directory, "booted"), "yes")
      when "install"
        if mode == "replace_artifact"
          source = File.join(directory, "source.swift")
          File.write(source + ".replacement", File.read(source))
          File.rename(source + ".replacement", source)
        end
      when "test"
        if %w[hold_test panic_during_test].include?(mode)
          descendant = fork { sleep 60 }
          File.write(File.join(directory, "worker-ready.json"), JSON.generate(
            "pid" => Process.pid, "descendant" => descendant, "pgid" => Process.getpgrp))
          File.write(File.join(directory, "new-panic"), "owned panic fixture") if mode == "panic_during_test"
          sleep 60
        else
          sleep 0.06
        end
      when "terminate"
        if mode == "cleanup_resource_deny"
          # The first denial is emitted only after cleanup starts, with an
          # acknowledgement rather than a race against the monitor interval.
          server = UNIXServer.new(File.join(directory, "deny.socket"))
          File.write(File.join(directory, "deny-requested"), "cleanup started")
          client = server.accept
          abort "missing resource denial acknowledgement" unless client.read == "sample flushed"
          client.close
          server.close
        end
      when "shutdown"
        exit 19 if mode == "cleanup_failure"
        if mode == "cleanup_timeout"
          descendant = fork { sleep 60 }
          File.write(File.join(directory, "cleanup-worker.json"), JSON.generate(
            "pid" => Process.pid, "descendant" => descendant, "pgid" => Process.getpgrp))
          sleep 60
        end
        # Cleanup still owns the same lease while the target is shutting down.
        File.open(File.join(directory, "heavy.lease"), "a+") do |lease|
          abort "lease was released before cleanup" if lease.flock(File::LOCK_EX | File::LOCK_NB)
        end
        FileUtils.rm_f(File.join(directory, "booted"))
      when "verify"
        exit 19 if File.exist?(File.join(directory, "booted"))
        puts JSON.generate("shutdown" => true, "simulator_app_absent" => true,
                           "simmetalhost_absent" => true)
      end
    RUBY
    xctestrun = File.join(@directory, "tests.xctestrun")
    File.write(xctestrun, <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>UnitTests</key><dict>
      <key>TestHostPath</key><string>#{host}</string>
      </dict></dict></plist>
    XML
    @plan = {
      "schema_version" => 1,
      "device" => { "uuid" => UUID, "name" => "iPhone SE",
                    "device_type" => "com.apple.CoreSimulator.SimDeviceType.iPhone-SE",
                    "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-15-5" },
      "xcode_path" => "/Applications/Xcode-16.4.0.app/Contents/Developer",
      "xcode_version" => "16.4", "source_revision" => "a" * 40,
      "source_root" => @directory,
      "files" => { "source" => source, "test_host" => host,
                   "xctestrun" => xctestrun, "monitor" => @tool }.transform_values do |path|
        { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest }
      end,
      "tests" => ["EpubToMp3Tests/BundledConverterFFISmokeTests/testAppBundledRustLibraryLoadsAndReturnsCatalog"],
      "duration_seconds" => 15.0, "phase_timeout_seconds" => 2.0,
      "cleanup_timeout_seconds" => 6.0
    }
    File.write(@plan_path, JSON.generate(@plan))
  end

  def teardown
    if passed?
      FileUtils.remove_entry(@directory)
    else
      warn "Retained fake session evidence: #{@directory}"
    end
  end

  def load_subject
    require_relative "native_simulator_session"
  end

  def run_session(mode: "success")
    load_subject
    NativeSimulatorSession.run(plan_path: @plan_path,
                              backend: FakeBackend.new(@directory, mode: mode),
                              lock_path: @lease, report_path: @report)
  end

  def operations
    File.exist?(@marker) ? File.readlines(@marker).map { |line| JSON.parse(line) } : []
  end

  def wait_for_fixture
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
    loop do
      result = yield
      return result if result
      flunk "Timed out waiting for owned fake fixture\n#{failure_diagnostics}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def read_fixture_json(path)
    JSON.parse(File.read(path)) if File.file?(path)
  rescue JSON::ParserError
    nil
  end

  def live_process?(pid)
    # A killed grandchild may briefly await init's reaper; it cannot hold FDs.
    stat = File.read("/proc/#{pid}/stat")
    stat.sub(/\A.*\) /, "").split.first != "Z"
  rescue Errno::ENOENT
    false
  end

  def with_held_session
    load_subject
    result_path = File.join(@directory, "owner-result.json")
    owner = fork do
      result = run_session(mode: "hold_test")
      File.write(result_path, JSON.generate("result" => result))
      exit! 0
    end
    worker = wait_for_fixture { read_fixture_json(File.join(@directory, "worker-ready.json")) }
    report = read_fixture_json(@report)
    assert_equal report.fetch("process_groups").first, worker.fetch("pgid")
    yield owner, report.fetch("caretaker_pid"), worker, result_path
  ensure
    if owner
      begin
        if Process.waitpid(owner, Process::WNOHANG).nil?
          Process.kill("TERM", owner)
          wait_for_fixture { Process.waitpid(owner, Process::WNOHANG) }
        end
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def assert_workers_stopped_and_lease_released(worker)
    wait_for_fixture { !live_process?(worker.fetch("pid")) && !live_process?(worker.fetch("descendant")) }
    available = wait_for_fixture do
      File.open(@lease, "a+") { |lease| lease.flock(File::LOCK_EX | File::LOCK_NB) }
    end
    assert available
  end

  def with_monitor_fixture(policy_changes: {}, sample_changes: {})
    load_subject
    reader, writer = IO.pipe
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    policy = { "event" => "policy", "limits" => NativeSimulatorSession::Monitor::LIMITS,
               "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
               "duration_seconds" => 15.0, "interval_seconds" => 0.1 }.merge(policy_changes)
    sample = { "started_monotonic" => now, "collected_monotonic" => now,
               "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
               "logical_cpus" => 8, "memory_free_percent" => 58,
               "disk_free_bytes" => 12 * 1024**3, "swap_used_bytes" => 0,
               "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => [] }.merge(sample_changes)
    writer.write(JSON.generate(policy) + "\n" + JSON.generate(
      "event" => "sample", "decision" => "allow", "reasons" => [], "sample" => sample) + "\n")
    writer.flush
    yield NativeSimulatorSession::Monitor.new(reader, StringIO.new, 15.0)
  ensure
    reader&.close
    writer&.close
  end

  def failure_diagnostics
    # These files contain only the owned fake process fixture, never host queries.
    paths = [@report, @marker] + Dir.glob(File.join(@directory, ".session-logs-*", "*"))
    paths.first(16).filter_map do |path|
      next unless File.file?(path) && !File.symlink?(path)
      next unless File.realpath(path).start_with?(File.realpath(@directory) + File::SEPARATOR)

      tail = File.open(path, "rb") do |file|
        file.seek([file.size - 2048, 0].max)
        file.read(2048) || +""
      end
      "#{path}:\n#{tail.force_encoding(Encoding::UTF_8).scrub}"
    end.join("\n")
  end

  def test_failure_diagnostics_accepts_empty_owned_logs
    logs = File.join(@directory, ".session-logs-empty")
    FileUtils.mkdir_p(logs)
    empty_log = File.join(logs, "1-boot.log")
    File.write(empty_log, "")
    File.write(@report, JSON.generate("decision" => "deny", "reason" => "fake failure"))
    diagnostics = failure_diagnostics
    assert_includes diagnostics, empty_log
    assert_includes diagnostics, "fake failure"
  end

  def test_production_entry_is_quarantined_before_any_child_even_with_environment_override
    output, error, status = Open3.capture3(
      { "EPUB2MP3_ALLOW_INTEL_SIMULATOR" => "1", "SESSION_FIXTURE" => @directory },
      RUBY, SCRIPT, "--plan", @plan_path
    )
    assert_equal 75, status.exitstatus, output + error
    assert_match(/quarantin/i, error)
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_success_orders_fixed_phases_and_confirms_cleanup_before_releasing_lease
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session
    assert_equal 0, result, failure_diagnostics
    phases = operations.map { |row| row.fetch("phase") }
    assert_equal %w[boot install test terminate shutdown quit verify], phases.reject { |phase| phase == "inspect" }
    assert_equal 8, phases.count("inspect"), "Target identity must be inspected again before every phase"
    report = JSON.parse(File.read(@report))
    assert_equal "allow", report.fetch("decision")
    assert_equal true, report.fetch("cleanup_verified")
    assert_equal 2, report.fetch("process_groups").length
    group = ->(phase) { operations.find { |row| row["phase"] == phase }.fetch("pgid") }
    assert_equal group.call("boot"), group.call("test")
    assert_equal group.call("terminate"), group.call("verify")
    refute_equal group.call("test"), group.call("verify")
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_resource_denial_first_received_during_cleanup_preserves_denied_outcome
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session(mode: "cleanup_resource_deny")
    report = JSON.parse(File.read(@report))
    assert_equal true, report.fetch("cleanup_verified"), failure_diagnostics
    assert_includes operations.map { |row| row.fetch("phase") }, "verify"
    assert_equal 75, result, failure_diagnostics
    assert_equal "deny", report.fetch("decision")
    assert_equal "Resource monitor denied session", report.fetch("reason")
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_owner_sigkill_leaves_caretaker_to_confirm_cleanup_and_release_descendant_lease
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, _caretaker, worker, _result_path|
      Process.kill("KILL", owner)
      Process.waitpid(owner)
      report = wait_for_fixture do
        value = read_fixture_json(@report)
        value if value && value["cleanup_verified"] == true
      end
      assert_equal "deny", report.fetch("decision")
      assert_match(/owner disappeared or cancelled/, report.fetch("reason"))
      assert_includes operations.map { |row| row.fetch("phase") }, "verify"
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  def test_caretaker_sigkill_terminates_owned_descendants_and_reports_incomplete_cleanup
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, caretaker, worker, result_path|
      Process.kill("KILL", caretaker)
      result = wait_for_fixture { read_fixture_json(result_path) }
      Process.waitpid(owner)
      assert_equal 75, result.fetch("result")
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match(/Caretaker lost; cleanup incomplete/, report.fetch("reason"))
      refute_includes operations.map { |row| row.fetch("phase") }, "shutdown"
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  def test_owner_sigterm_cancels_work_and_confirms_cleanup_before_returning_signal_status
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, _caretaker, worker, result_path|
      Process.kill("TERM", owner)
      result = wait_for_fixture { read_fixture_json(result_path) }
      Process.waitpid(owner)
      assert_equal 143, result.fetch("result")
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal true, report.fetch("cleanup_verified"), failure_diagnostics
      assert_match(/owner disappeared or cancelled/, report.fetch("reason"))
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  {
    "old_start_with_fresh_finish_and_zero_duration" => [-100.0, 0.0],
    "actual_collection_exceeds_budget" => [-6.0, 5.0],
    "declared_duration_disagrees_with_elapsed_collection" => [-0.25, 0.0],
    "collection_starts_after_its_finish" => [1.0, 0.0]
  }.each do |name, (start_offset, declared_duration)|
    define_method("test_monitor_rejects_#{name}") do
      load_subject
      reader, writer = IO.pipe
      monitor = NativeSimulatorSession::Monitor.new(reader, StringIO.new, 15.0)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      started = start_offset == -100.0 ? now - [100.0, now / 2].min : now + start_offset
      policy = { "event" => "policy", "limits" => NativeSimulatorSession::Monitor::LIMITS,
                 "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
                 "duration_seconds" => 15.0, "interval_seconds" => 0.1 }
      sample = { "event" => "sample", "decision" => "allow", "reasons" => [],
                 "sample" => { "started_monotonic" => started,
                   "collected_monotonic" => now, "collection_seconds" => declared_duration,
                   "memory_bytes" => 8 * 1024**3, "logical_cpus" => 8,
                   "memory_free_percent" => 58, "disk_free_bytes" => 12 * 1024**3,
                   "swap_used_bytes" => 0, "load_averages" => [1.0, 1.0, 1.0],
                   "panic_identities" => [] } }
      writer.write(JSON.generate(policy) + "\n" + JSON.generate(sample) + "\n")
      writer.flush
      # Keep the producer open: EOF must not accidentally satisfy this denial.
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/Invalid or replayed resource sample/, error.message)
    ensure
      reader&.close
      writer&.close
    end
  end

  def test_old_collection_start_prevents_any_session_phase_from_launching
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session(mode: "old_collection_start")
    assert_equal 75, result, failure_diagnostics
    assert_empty operations
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/Invalid or replayed resource sample/, report.fetch("reason"))
  end

  def test_monitor_rejects_changed_resource_policy
    with_monitor_fixture(policy_changes: { "limits" => {} }) do |monitor|
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/policy mismatch/, error.message)
    end
  end

  def test_monitor_rejects_stale_sample_even_when_collection_duration_is_valid
    finished = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 6
    with_monitor_fixture(sample_changes: { "started_monotonic" => finished, "collected_monotonic" => finished }) do |monitor|
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/sample is stale/, error.message)
    end
  end

  { "monitor_eof" => /ended unexpectedly/, "initial_resource_deny" => /denied session/ }.each do |mode, reason|
    define_method("test_#{mode}_prevents_any_owned_phase") do
      skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
      assert_equal 75, run_session(mode: mode), failure_diagnostics
      assert_empty operations
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match reason, report.fetch("reason")
    end
  end

  def test_new_panic_stops_owned_groups_without_starting_fresh_cleanup_commands
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    assert_equal 75, run_session(mode: "panic_during_test"), failure_diagnostics
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal true, report.fetch("fatal_panic")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/New panic report detected/, report.fetch("reason"))
    phases = operations.map { |row| row.fetch("phase") }
    assert_equal "test", phases.last
    %w[terminate shutdown quit verify].each { |phase| refute_includes phases, phase }
    worker = read_fixture_json(File.join(@directory, "worker-ready.json"))
    assert_equal report.fetch("process_groups").first, worker.fetch("pgid")
    assert_workers_stopped_and_lease_released(worker)
  end

  def test_same_content_artifact_replacement_prevents_next_phase_and_cleanup_claim
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    assert_equal 75, run_session(mode: "replace_artifact"), failure_diagnostics
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/Artifact identity changed/, report.fetch("reason"))
    assert_match(/Artifact identity changed/, report.fetch("cleanup_error"))
    assert_equal "install", operations.last.fetch("phase")
    refute_includes operations.map { |row| row.fetch("phase") }, "test"
  end

  { "cleanup_failure" => /shutdown failed with status 19/,
    "cleanup_timeout" => /Session deadline exceeded/ }.each do |mode, reason|
    define_method("test_#{mode}_reports_incomplete_cleanup_and_bounded_failure") do
      skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 75, run_session(mode: mode), failure_diagnostics
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 16.5
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match reason, report.fetch("cleanup_error")
      refute_includes operations.map { |row| row.fetch("phase") }, "verify"
      if mode == "cleanup_timeout"
        worker = read_fixture_json(File.join(@directory, "cleanup-worker.json"))
        assert_equal report.fetch("process_groups").last, worker.fetch("pgid")
        assert_workers_stopped_and_lease_released(worker)
      end
    end
  end
end
