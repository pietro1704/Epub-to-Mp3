# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "simulator_backend"

class SimulatorBackendTest < Minitest::Test
  DEVICE = "11111111-1111-1111-1111-111111111111"
  class Backend < SimulatorBackend
    attr_accessor :rows, :running
    def capture(*, **)
      ""
    end
    def devices
      { RUNTIME => rows }
    end
    def processes
      running || []
    end
  end

  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "executable"), "fixture")
    @backend = Backend.new(device: DEVICE, app: @dir, directory: @dir)
    @backend.rows = [{ "udid" => DEVICE, "state" => "Shutdown", "isAvailable" => true,
                       "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-SE" }]
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_only_explicit_available_shutdown_se_identity_is_admitted
    assert_nil @backend.recheck
    [{ "state" => "Booted" }, { "isAvailable" => false }, { "udid" => "different" },
     { "deviceTypeIdentifier" => "iPad" }].each do |change|
      original = @backend.rows
      @backend.rows = [original.first.merge(change)]
      assert_raises(SimulatorResources::Refusal) { @backend.recheck }
      @backend.rows = original
    end
  end

  def test_existing_ui_or_compiler_refuses_before_boot
    ["/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", "/usr/bin/xcodebuild"].each do |path|
      @backend.running = [[123, path]]
      assert_raises(SimulatorResources::Refusal) { @backend.recheck }
    end
  end

  def test_mutated_app_and_symlink_fail_identity_check
    @backend.instance_variable_set(:@app_fingerprint, @backend.app_fingerprint)
    File.write(File.join(@dir, "executable"), "changed")
    assert_raises(SimulatorResources::Refusal) { @backend.recheck }
    assert_raises(SimulatorResources::Refusal) { @backend.prepare(:install) }
    File.symlink("executable", File.join(@dir, "alias"))
    assert_raises(SimulatorResources::Refusal) { @backend.app_fingerprint }
  end

  def test_identity_accepts_15_2_but_rejects_wrong_or_unavailable_runtime
    File.write(File.join(@dir, "Info.plist"), "fixture")
    @backend.instance_variable_set(:@fixture_runtime, {
      "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-15-2", "isAvailable" => true,
      "supportedArchitectures" => ["x86_64"]
    })
    @backend.define_singleton_method(:capture) do |*argv, **|
      case
      when argv == ["/usr/bin/xcodebuild", "-version"] then "Xcode 26.3\nBuild version 17C503\n"
      when argv.include?("runtimes") then JSON.generate("runtimes" => [@fixture_runtime])
      when argv.include?("CFBundleIdentifier") then "com.pietrocode.epubtomp3"
      when argv.include?("CFBundleExecutable") then "executable"
      when argv.include?("MinimumOSVersion") then "15.0"
      when argv.include?("-archs") then "x86_64"
      when argv.include?("vtool") then "platform IOSSIMULATOR"
      else ""
      end
    end
    identity = @backend.inspect_identity(host: "x86_64-darwin")
    assert_equal "com.apple.CoreSimulator.SimRuntime.iOS-15-2", identity["runtime"]["identifier"]
    @backend.instance_variable_get(:@fixture_runtime)["isAvailable"] = false
    assert_raises(SimulatorResources::Refusal) { @backend.inspect_identity(host: "x86_64-darwin") }
    @backend.instance_variable_get(:@fixture_runtime).merge!(
      "isAvailable" => true, "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-15-0"
    )
    assert_raises(SimulatorResources::Refusal) { @backend.inspect_identity(host: "x86_64-darwin") }
  end

  def test_cleanup_terminates_only_its_unreaped_ui_child
    owned = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
    unrelated = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
    @backend.instance_variable_set(:@ui_pid, owned)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal "verified_shutdown", @backend.cleanup
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 5
    assert_raises(Errno::ECHILD) { Process.waitpid(owned, Process::WNOHANG) }
    assert_nil Process.waitpid(unrelated, Process::WNOHANG), "unrelated process was terminated"
  ensure
    [owned, unrelated].compact.each do |pid|
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end
end
