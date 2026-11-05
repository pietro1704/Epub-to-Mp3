# frozen_string_literal: true

require "digest"
require_relative "simulator_resources"
require_relative "mac_build_budget"

class SimulatorBackend
  DEVELOPER = "/Applications/Xcode-16.4.0.app/Contents/Developer"
  RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-15-0"

  def initialize(device:, app:, directory:)
    raise SimulatorResources::Refusal, "Invalid device UUID" unless device.match?(/\A[0-9A-Fa-f-]{36}\z/)
    @device, @app, @directory = device, File.realpath(app), directory
    @environment = { "DEVELOPER_DIR" => DEVELOPER }
  end

  def capture(*argv, seconds: 4)
    SimulatorResources.capture(*argv, seconds: seconds, environment: @environment)
  end

  def devices
    payload = JSON.parse(capture("/usr/bin/xcrun", "simctl", "list", "devices", "-j"))
    groups = payload.fetch("devices")
    raise SimulatorResources::Refusal, "Invalid devices" unless groups.is_a?(Hash)
    groups
  end

  def processes
    capture("/bin/ps", "-axo", "pid=,comm=").lines.filter_map do |line|
      pid, executable = line.strip.split(/\s+/, 2)
      next unless executable
      [Integer(pid), executable]
    end
  end

  def simulator_processes
    processes.select { |_, path| path.include?("SimMetalHost") || path.end_with?("/Simulator.app/Contents/MacOS/Simulator") }
  end

  def recheck
    Timeout.timeout(12) { recheck_state }
  rescue Timeout::Error
    raise SimulatorResources::Refusal, "Identity recheck deadline exceeded"
  end

  def recheck_state
    rows = devices.values.flatten
    raise SimulatorResources::Refusal, "A simulator is not shut down" unless rows.all? { |row| row.fetch("state") == "Shutdown" }
    owned = devices.fetch(RUNTIME).find { |row| row["udid"] == @device }
    raise SimulatorResources::Refusal, "Device identity changed" unless owned && owned["isAvailable"] == true
    unless owned["deviceTypeIdentifier"] == "com.apple.CoreSimulator.SimDeviceType.iPhone-SE"
      raise SimulatorResources::Refusal, "First-generation iPhone SE required"
    end
    if @app_fingerprint && app_fingerprint != @app_fingerprint
      raise SimulatorResources::Refusal, "Application changed after inspection"
    end
    raise SimulatorResources::Refusal, "Simulator or SimMetalHost already running" unless simulator_processes.empty?
    heavy = processes.select { |_, path| %w[xcodebuild cargo rustc swift-frontend converter-cli].include?(File.basename(path)) }
    raise SimulatorResources::Refusal, "Other native workload is running" unless heavy.empty?
    capture(RbConfig.ruby, File.join(__dir__, "mac_build_budget.rb"), "check", seconds: 8)
    nil
  end

  def inspect_identity
    raise SimulatorResources::Refusal, "Intel macOS required" unless RUBY_PLATFORM.match?(/x86_64.*darwin/)
    versions = capture("/usr/bin/xcodebuild", "-version")
    raise SimulatorResources::Refusal, "Xcode 16.4 required" unless versions.lines.first&.strip == "Xcode 16.4"
    runtimes = JSON.parse(capture("/usr/bin/xcrun", "simctl", "list", "runtimes", "-j")).fetch("runtimes")
    runtime = runtimes.find { |row| row["identifier"] == RUNTIME }
    unless runtime && runtime["isAvailable"] == true && runtime.fetch("supportedArchitectures", []).include?("x86_64")
      raise SimulatorResources::Refusal, "Available Intel iOS 15.0 runtime required"
    end
    recheck
    info = File.join(@app, "Info.plist")
    @bundle = capture("/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", info).strip
    raise SimulatorResources::Refusal, "Unexpected application" unless @bundle == "com.pietrocode.epubtomp3"
    name = capture("/usr/bin/plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", info).strip
    raise SimulatorResources::Refusal, "Invalid executable name" unless name.match?(/\A[A-Za-z0-9_.-]+\z/)
    binary = File.join(@app, name)
    architectures = capture("/usr/bin/lipo", "-archs", binary).split
    raise SimulatorResources::Refusal, "App lacks x86_64" unless architectures.include?("x86_64")
    platform = capture("/usr/bin/xcrun", "vtool", "-arch", "x86_64", "-show-build", binary)
    raise SimulatorResources::Refusal, "App is not an iOS Simulator binary" unless platform.match?(/platform\s+IOSSIMULATOR/)
    minimum = capture("/usr/bin/plutil", "-extract", "MinimumOSVersion", "raw", "-o", "-", info).strip
    raise SimulatorResources::Refusal, "App minimum exceeds iOS 15.0" unless minimum.match?(/\A\d+(?:\.\d+){0,2}\z/) && (minimum.split('.').map(&:to_i) <=> [15, 0, 0]) <= 0
    @app_fingerprint = app_fingerprint
    { "device" => @device, "runtime" => runtime, "xcode" => versions.strip,
      "app" => @app, "bundle" => @bundle, "executable_sha256" => Digest::SHA256.file(binary).hexdigest }
  end

  def app_fingerprint
    Timeout.timeout(8) { fingerprint_files }
  rescue Timeout::Error
    raise SimulatorResources::Refusal, "Application fingerprint deadline exceeded"
  end

  def fingerprint_files
    Digest::SHA256.hexdigest(Dir.glob(File.join(@app, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
      next if [".", ".."].include?(File.basename(path))
      raise SimulatorResources::Refusal, "Symlink in app bundle" if File.symlink?(path)
      next unless File.file?(path)
      path.delete_prefix(@app) + ":" + Digest::SHA256.file(path).hexdigest
    end.join("\n"))
  end

  def check_ui
    return unless @ui_pid
    result = Process.waitpid2(@ui_pid, Process::WNOHANG)
    return unless result
    @ui_pid = nil
    raise SimulatorResources::Refusal, "Owned Simulator UI exited unexpectedly"
  end

  def prepare(stage)
    if stage == :install && app_fingerprint != @app_fingerprint
      raise SimulatorResources::Refusal, "Application changed before installation"
    end
  end

  def start(stage)
    raise SimulatorResources::Refusal, "Previous command still active" if @pid
    argv = case stage
           when :boot then ["/usr/bin/xcrun", "simctl", "boot", @device]
           when :ready then ["/usr/bin/xcrun", "simctl", "bootstatus", @device, "-b"]
           when :ui then [File.join(DEVELOPER, "Applications/Simulator.app/Contents/MacOS/Simulator"), "-CurrentDeviceUDID", @device]
           when :install then ["/usr/bin/xcrun", "simctl", "install", @device, @app]
           when :launch then ["/usr/bin/xcrun", "simctl", "launch", @device, @bundle]
           else raise SimulatorResources::Refusal, "Unknown stage"
           end
    @log = File.open(File.join(@directory, "#{stage}.log"), "wx", 0o600)
    @pid = Process.spawn(@environment, *argv, pgroup: true, out: @log, err: @log)
    if stage == :ui
      @ui_pid = @pid
      @pid = nil
      @log.close
      @ui_started = true
    end
  end

  def poll
    if @ui_started
      @ui_started = false
      return 0
    end
    result = Process.waitpid2(@pid, Process::WNOHANG)
    return nil unless result
    @pid = nil
    @log.close
    result.last.exitstatus || 75
  end

  def cleanup
    Timeout.timeout(30) { perform_cleanup }
  rescue Timeout::Error
    raise SimulatorResources::Refusal, "Shutdown deadline exceeded"
  end

  def perform_cleanup
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    if @pid
      Process.kill("KILL", -@pid) rescue Errno::ESRCH
      until Process.waitpid(@pid, Process::WNOHANG)
        sleep 0.05
      end
      @pid = nil
      @log&.close
    end
    # Shutting down this initially-idle device terminates its application too.
    begin
      capture("/usr/bin/xcrun", "simctl", "shutdown", @device, seconds: 10)
    rescue SimulatorResources::Refusal
      # A failed boot can already be Shutdown; verify instead of ignoring state.
    end
    if @ui_pid
      # This unreaped child retains its PID identity; never kill a process found by name.
      Process.kill("TERM", -@ui_pid) rescue Errno::ESRCH
    end
    termination_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      if @ui_pid && Process.clock_gettime(Process::CLOCK_MONOTONIC) - termination_started >= 2
        Process.kill("KILL", -@ui_pid) rescue Errno::ESRCH
      end
      owned = devices.fetch(RUNTIME).find { |row| row["udid"] == @device }
      raise SimulatorResources::Refusal, "Device disappeared during cleanup" unless owned
      if @ui_pid
        result = Process.waitpid2(@ui_pid, Process::WNOHANG)
        @ui_pid = nil if result
      end
      residual = simulator_processes
      raise SimulatorResources::Refusal, "Shutdown deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      return "verified_shutdown" if owned["state"] == "Shutdown" && @ui_pid.nil? && residual.empty?
      raise SimulatorResources::Refusal, "Shutdown deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.25
    end
  end
end
