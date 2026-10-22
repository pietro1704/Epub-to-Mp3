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
require "shellwords"

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
    @directory = File.realpath(Dir.mktmpdir("simulator-session-contract-"))
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
        exit 19 if mode == "boot_failure_after_start"
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

  def run_session(mode: "success", backend: nil)
    load_subject
    NativeSimulatorSession.run(plan_path: @plan_path,
                              backend: backend || FakeBackend.new(@directory, mode: mode),
                              lock_path: @lease, report_path: @report)
  end

  def operations
    File.exist?(@marker) ? File.readlines(@marker).map { |line| JSON.parse(line) } : []
  end

  def plan_with_test_bundle_xml(value)
    load_subject
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key>#{value}</dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))
    NativeSimulatorSession::Plan.new(@plan_path)
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

  # Scoped Ruby method replacement; Minitest 6 no longer includes minitest/mock.
  def with_method(receiver, name, replacement)
    own_method = receiver.singleton_class.instance_methods(false).include?(name)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    if own_method
      receiver.define_singleton_method(name, original)
    else
      receiver.singleton_class.remove_method(name)
    end
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

  def fixture_process_identity(pid)
    fields = File.read("/proc/#{pid}/stat").sub(/\A.*\) /, "").split
    return nil if fields.first == "Z"
    [pid, Integer(fields.fetch(2)), fields.fetch(19)]
  rescue Errno::ENOENT
    nil
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

require_relative "native_session_artifact_identity_cases"

require_relative "native_session_hashing_cases"

require_relative "native_session_lifecycle_cases"

require_relative "native_session_resource_policy_cases"
