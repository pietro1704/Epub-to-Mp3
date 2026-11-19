#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "json"
require "rbconfig"
require "etc"
require_relative "native_build_preflight"
require_relative "mac_build_budget"

# One lease spans inspection and execution. Descendants receive the actual open
# file description, never an environment-only permission to skip coordination.
module NativeJob
  LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
  CHILD_FD = 9
  FD_ENV = "EPUB_NATIVE_LEASE_FD"
  PATH_ENV = "EPUB_NATIVE_LEASE_PATH"
  BUILD_DIRS_ENV = "EPUB_NATIVE_BUILD_DIRECTORIES"
  # GitHub-hosted runners are disposable VMs without this Mac's kernel-panic
  # history; the owner approved parallel Cargo/CMake there (2026-11-19). Every
  # other host, including this Mac, keeps exactly one compiler job.
  # Environment variables alone can be copied into a local shell, so the hosted
  # runner's account home is also required. A lower CARGO_BUILD_JOBS set by the
  # caller (for example a workflow that pins 1) is honored.
  HOSTED_BUILD_JOBS_CAP = 4
  HOSTED_RUNNER_HOMES = %w[/Users/runner /home/runner].freeze

  def self.account_home
    Etc.getpwuid(Process.uid)&.dir
  rescue ArgumentError
    nil
  end

  def self.build_jobs(environment = ENV, processors: Etc.nprocessors, home: account_home)
    hosted = environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted" &&
             !environment["ImageOS"].to_s.empty? && HOSTED_RUNNER_HOMES.include?(home)
    return 1 unless hosted

    allowance = Integer(processors).clamp(1, HOSTED_BUILD_JOBS_CAP)
    requested = environment["CARGO_BUILD_JOBS"].to_s
    requested.match?(/\A[1-9]\d*\z/) ? [allowance, Integer(requested, 10)].min : allowance
  end

  # Forward only the authenticated lease when a Ruby driver starts another
  # guarded driver. Explicit mapping preserves it even with close_others:true.
  def self.child_options
    return {} unless ENV[FD_ENV] || ENV[PATH_ENV]

    handle, = lease(LOCK_PATH)
    { CHILD_FD => handle }
  end

  # Ruby build drivers call this before preparation or compiler work. The first
  # invocation becomes a supervised child; that child validates its real inherited
  # lease and rechecks host state without opening a second independent lock.
  def self.build_entrypoint(file, arguments = [], build_dir: nil)
    command = [RbConfig.ruby, File.expand_path(file), *arguments]
    unless ENV[FD_ENV] || ENV[PATH_ENV]
      exit run(phase: "build", command: command, build_dir: build_dir)
    end
    lease(LOCK_PATH)
    destinations = build_directories([], build_dir, inherited: true)
    monitored = JSON.parse(ENV.fetch(BUILD_DIRS_ENV, "[]"))
    # An outer driver may supervise a different output volume. Keep its lease
    # and add a supervisor for this driver's outputs until this child exits.
    unless (destinations - monitored).empty?
      exit run(phase: "build", command: command, build_dir: destinations)
    end
    error = NativeBuildPreflight.check || MacBuildBudget.check(*destinations)
    if error
      warn error
      exit 75
    end
    nil
  rescue StandardError => error
    warn "native_job: #{error.message}"
    exit 75
  end

  def self.lease(path)
    inherited = ENV[FD_ENV]
    if inherited || ENV[PATH_ENV]
      raise "Invalid inherited native lease" unless inherited&.match?(/\A\d+\z/) && ENV[PATH_ENV] == path
      handle = File.for_fd(Integer(inherited), autoclose: false)
      stat = handle.stat
      expected = File.stat(path)
      raise "Inherited native lease points to another file" unless stat.file? && [stat.dev, stat.ino] == [expected.dev, expected.ino]
      # An independently opened descriptor must be excluded, while the inherited
      # description can reassert the lock. Both are required to reject stale FDs.
      File.open(path, "a+") do |probe|
        if probe.flock(File::LOCK_EX | File::LOCK_NB)
          probe.flock(File::LOCK_UN)
          raise "Inherited native lease is no longer held"
        end
      end
      raise "Inherited native lease does not own the lock" unless handle.flock(File::LOCK_EX | File::LOCK_NB)
      return [handle, true]
    end
    handle = File.open(path, "a+")
    unless handle.flock(File::LOCK_EX | File::LOCK_NB)
      handle.close
      raise "Another native/heavy job is active"
    end
    [handle, false]
  end

  def self.stop_group(pid)
    Process.kill("TERM", -pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.5
    loop do
      Process.kill(0, -pid)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  def self.parallelism_error(command)
    return nil unless RUBY_PLATFORM.include?("darwin")
    compiler = command.index { |part| %w[cargo xcodebuild swift cmake].include?(File.basename(part)) }
    return nil unless compiler
    arguments = command.drop(compiler + 1)
    arguments.each_with_index do |part, index|
      return "Parallel native targets are disabled on this Mac" if part == "-parallelizeTargets"
      flag = %w[-jobs --jobs -j].include?(part)
      flag ||= File.basename(command[compiler]) == "cmake" && part == "--parallel"
      compact = part.match(/\A-j(-?\d+)\z/) || part.match(/\A--(?:jobs|parallel)=(.+)\z/)
      next unless flag || compact
      number = flag ? arguments[index + 1] : compact[1]
      next if number == "1"
      # Only Cargo and CMake use the hosted-runner allowance; Xcode and Swift stay serial.
      hosted = %w[cargo cmake].include?(File.basename(command[compiler])) && build_jobs > 1
      allowed = hosted && number.to_s.match?(/\A[1-9]\d*\z/) && Integer(number, 10) <= build_jobs
      return "Mac compilation requires exactly one job" unless allowed
    end
    nil
  end

  def self.option_path(arguments, name)
    arguments.each_with_index do |part, index|
      return arguments.fetch(index + 1) if part == name
      return part.delete_prefix(name + "=") if part.start_with?(name + "=")
    end
    nil
  end

  def self.build_directories(command, explicit, inherited:)
    return Array(explicit).map { |dir| File.expand_path(dir) }.uniq unless Array(explicit).empty?

    index = command.index { |part| %w[cargo xcodebuild swift].include?(File.basename(part)) }
    if index
      # mise -C changes the compiler's working directory before it starts.
      cwd = Dir.pwd
      prefix = command.take(index)
      mise = prefix.index { |part| File.basename(part) == "mise" }
      cwd = option_path(prefix.drop(mise + 1), "-C") || cwd if mise
      args = command.drop(index + 1).take_while { |arg| arg != "--" }
      directory = case File.basename(command[index])
                  when "cargo"
                    option_path(args, "--target-dir") || ENV["CARGO_TARGET_DIR"] || ENV["CARGO_BUILD_TARGET_DIR"] ||
                      File.join(MacBuildBudget::ROOT, "target")
                  when "xcodebuild"
                    option_path(args, "-derivedDataPath") || ENV["APPLE_DERIVED_DATA_PATH"]
                  when "swift"
                    option_path(args, "--scratch-path") ||
                      (File.join(option_path(args, "--package-path") || ".", ".build") if %w[build run test].include?(args.first))
                  end
      return [File.expand_path(directory, cwd)] if directory && !directory.empty?
    end
    return JSON.parse(ENV.fetch(BUILD_DIRS_ENV)) if inherited && ENV[BUILD_DIRS_ENV]

    [Dir.pwd]
  end

  def self.run(phase:, command:, path: LOCK_PATH, build_dir: nil)
    # Recurrent IGGuC.cpp:2913 panics occurred inside SimMetalHost on this
    # Intel host. A lease cannot make the GPU driver safe. Keep Simulator
    # execution quarantined; neither inherited leases nor environment flags
    # authorize another attempt. Use physical-device verification instead.
    if phase == "simulator" && RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
      warn "Intel Simulator execution is quarantined after recurrent IGGuC/SimMetalHost kernel panics. Use physical-device verification; do not retry or boot Simulator."
      return 75
    end
    if phase == "build" && (error = parallelism_error(command))
      warn error
      return 75
    end
    path = File.expand_path(path)
    handle, inherited = lease(path)
    if phase == "build"
      destinations = build_directories(command, build_dir, inherited: inherited)
      error = NativeBuildPreflight.check || MacBuildBudget.check(*destinations)
      if error
        warn error
        return 75
      end
    end
    signal = nil
    previous = {}
    %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { signal ||= name } }
    environment = { FD_ENV => CHILD_FD.to_s, PATH_ENV => path,
                    "CARGO_BUILD_JOBS" => build_jobs.to_s, "CMAKE_BUILD_PARALLEL_LEVEL" => build_jobs.to_s }
    environment[BUILD_DIRS_ENV] = JSON.generate(destinations) if destinations
    pid = Process.spawn(environment, [command.first, command.first], *command.drop(1), CHILD_FD => handle, pgroup: true)
    status = nil
    cancelled_at = nil
    storage_error = nil
    storage_interval = MacBuildBudget.interval
    next_storage_check = Process.clock_gettime(Process::CLOCK_MONOTONIC) + storage_interval
    until status
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if phase == "build" && now >= next_storage_check && !storage_error
        storage_error = MacBuildBudget.check(*destinations)
        if storage_error
          warn storage_error
          signal ||= "TERM"
        end
        next_storage_check = now + storage_interval
      end
      if signal && !cancelled_at
        Process.kill(signal, -pid) rescue Errno::ESRCH
        cancelled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elsif cancelled_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - cancelled_at > 2
        Process.kill("KILL", -pid) rescue Errno::ESRCH
      end
      result = Process.waitpid2(pid, Process::WNOHANG)
      status = result&.last
      sleep 0.02 unless status
    end
    # The process leader may exit before a descendant that ignored termination.
    if signal || !status.success?
      # Give nested supervisors a chance to forward termination to their own group
      # before killing descendants that ignored it.
      stop_group(pid)
    end
    storage_error ? 75 : (signal ? 128 + Signal.list.fetch(signal) : (status.exitstatus || 128 + status.termsig))
  rescue StandardError => error
    warn "native_job: #{error.message}"
    75
  ensure
    if pid && !status
      # Unexpected host-side failures must not leave work running without its lease.
      stop_group(pid)
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    previous&.each { |name, handler| Signal.trap(name, handler) }
    handle&.close unless inherited
  end

  def self.main(arguments)
    options = { path: LOCK_PATH, build_dir: [] }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: native_job.rb [--lock-path PATH] [--build-dir PATH] build|simulator -- COMMAND [ARGS]"
      opts.on("--build-dir PATH") { |value| options[:build_dir] << value }
      # Explicit fixture isolation; production callers always use LOCK_PATH.
      opts.on("--lock-path PATH") { |value| options[:path] = value }
    end
    parser.order!(arguments)
    phase = arguments.shift
    arguments.shift if arguments.first == "--"
    unless %w[build simulator].include?(phase) && !arguments.empty?
      warn parser
      return 2
    end
    run(phase: phase, command: arguments, **options)
  rescue OptionParser::ParseError => error
    warn error.message
    2
  end
end

exit NativeJob.main(ARGV) if $PROGRAM_NAME == __FILE__
