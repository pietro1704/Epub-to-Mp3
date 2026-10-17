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
      if phase == "monitor"
        puts JSON.generate("event" => "policy", "limits" => {
          "minimum_free_percent" => 20, "minimum_disk_bytes" => 8 * 1024**3,
          "maximum_swap_growth_bytes" => 256 * 1024**2,
          "maximum_sample_seconds" => 5.0, "query_timeout_seconds" => 2.0
        }, "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
           "duration_seconds" => 3.0, "interval_seconds" => 0.1)
        STDOUT.sync = true
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          puts JSON.generate("event" => "sample", "decision" => "allow", "reasons" => [],
            "sample" => { "started_monotonic" => now, "collected_monotonic" => now,
              "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
              "logical_cpus" => 8, "memory_free_percent" => 58,
              "disk_free_bytes" => 12 * 1024**3, "swap_used_bytes" => 0,
              "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => [] })
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
      "duration_seconds" => 3.0, "phase_timeout_seconds" => 0.8,
      "cleanup_timeout_seconds" => 0.8
    }
    File.write(@plan_path, JSON.generate(@plan))
  end

  def teardown
    FileUtils.remove_entry(@directory)
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
    assert_equal 0, run_session
    assert_equal %w[inspect boot install test terminate shutdown quit verify],
                 operations.map { |row| row.fetch("phase") }
    report = JSON.parse(File.read(@report))
    assert_equal "allow", report.fetch("decision")
    assert_equal true, report.fetch("cleanup_verified")
    assert_equal 2, report.fetch("process_groups").length
    assert_equal operations[1].fetch("pgid"), operations[3].fetch("pgid")
    assert_equal operations[4].fetch("pgid"), operations[-1].fetch("pgid")
    refute_equal operations[3].fetch("pgid"), operations[-1].fetch("pgid")
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end
end
