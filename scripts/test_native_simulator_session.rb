# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "timeout"

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
        acknowledged = false
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          denied = mode == "cleanup_resource_deny" && File.exist?(File.join(directory, "deny-requested"))
          puts JSON.generate("event" => "sample", "decision" => denied ? "deny" : "allow",
            "reasons" => denied ? ["available disk space below minimum"] : [],
            "sample" => { "started_monotonic" => now, "collected_monotonic" => now,
              "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
              "logical_cpus" => 8, "memory_free_percent" => 58,
              "disk_free_bytes" => (denied ? 4 : 12) * 1024**3, "swap_used_bytes" => 0,
              "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => [] })
          STDOUT.flush
          if denied && !acknowledged
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
      when "test"
        sleep 0.06
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
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end
end
