#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "json"
require "rbconfig"
require "etc"
require "time"
require_relative "native_build_preflight"
require_relative "mac_build_budget"

# One lease spans inspection and execution. Descendants receive the actual open
# file description, never an environment-only permission to skip coordination.
module NativeJob
  # One absolute path for every worktree and session. /tmp is emptied at reboot;
  # the next job recreates the file, and no holder can survive a reboot.
  LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
  # Host admission, priority and flight recording belong to the one real host
  # lease. A fixture lease (an explicit --lock-path, or this script copied with
  # LOCK_PATH rewritten) exercises only the lease protocol, so host load never
  # leaks into host tests and those copies need no further files. This value is
  # deliberately not spelled like LOCK_PATH.
  HOST_LEASE = File.join("/tmp", "epub2mp3.heavy-job.lock")
  CHILD_FD = 9
  FD_ENV = "EPUB_NATIVE_LEASE_FD"
  PATH_ENV = "EPUB_NATIVE_LEASE_PATH"
  BUILD_DIRS_ENV = "EPUB_NATIVE_BUILD_DIRECTORIES"
  # Queue instead of polling: seconds to wait for the lease and for admission.
  WAIT_ENV = "EPUB_NATIVE_WAIT_SECONDS"
  LEASE_RETRY_SECONDS = 5
  PHASES = %w[build simulator heavy].freeze
  SESSION_KEYS = { "claude" => "CLAUDE_CODE_SESSION_ID", "herdr" => "HERDR_PANE_ID", "agent" => "AI_AGENT" }.freeze
  # GitHub-hosted runners are disposable VMs without this Mac's kernel-panic
  # history; the owner approved parallel Cargo/CMake there (2026-11-19). Every
  # other host, including this Mac, keeps exactly one compiler job.
  # Environment variables alone can be copied into a local shell, so the hosted
  # runner's account home is also required. A lower CARGO_BUILD_JOBS set by the
  # caller (for example a workflow that pins 1) is honored.
  HOSTED_BUILD_JOBS_CAP = 4
  HOSTED_RUNNER_HOMES = %w[/Users/runner /home/runner].freeze

  class Busy < RuntimeError; end

  def self.account_home
    Etc.getpwuid(Process.uid)&.dir
  rescue ArgumentError
    nil
  end

  def self.hosted_runner?(environment = ENV, home: account_home)
    environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted" &&
      !environment["ImageOS"].to_s.empty? && HOSTED_RUNNER_HOMES.include?(home)
  end

  def self.build_jobs(environment = ENV, processors: Etc.nprocessors, home: account_home)
    return 1 unless hosted_runner?(environment, home: home)

    allowance = Integer(processors).clamp(1, HOSTED_BUILD_JOBS_CAP)
    requested = environment["CARGO_BUILD_JOBS"].to_s
    requested.match?(/\A[1-9]\d*\z/) ? [allowance, Integer(requested, 10)].min : allowance
  end

  def self.host_services?(path, host: RUBY_PLATFORM)
    host.include?("darwin") && !hosted_runner? && File.expand_path(path) == HOST_LEASE
  end

  # Loaded on demand so a fixture copy of this script stays self-contained.
  def self.host_services
    require_relative "host_load"
    require_relative "native_flight_recorder"
  end

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

  # Full host suites fork for minutes and are a heavy class on this Mac. They
  # run under the host lease without receiving it, so every suite keeps its own
  # fixture isolation. Other hosts, including hosted CI, are unchanged.
  def self.heavy_entrypoint(file, arguments = [], path: LOCK_PATH)
    return nil unless host_services?(path)
    return nil if supervised?(path)

    exit run(phase: "heavy", command: [RbConfig.ruby, File.expand_path(file), *arguments], path: path, expose_lease: false)
  end

  def self.holder_record(phase, command)
    session = SESSION_KEYS.filter_map { |name, key| "#{name}=#{ENV[key]}" unless ENV[key].to_s.empty? }.join(" ")
    { "pid" => Process.pid, "phase" => phase, "state" => "starting", "command" => command.join(" ")[0, 200],
      "started" => Time.now.utc.iso8601, "worktree" => File.expand_path("..", __dir__), "cwd" => Dir.pwd,
      "session" => session }
  end

  # The lease file names its holder while held and is empty otherwise.
  def self.publish(handle, record)
    handle.truncate(0)
    handle.write(JSON.generate(record) + "\n") if record
    handle.flush
  end

  # Advisory: an older checkout holds the same lease without publishing a record.
  def self.holder(path)
    record = JSON.parse(File.read(path))
    return nil unless record.is_a?(Hash) && record["pid"].is_a?(Integer)

    Process.kill(0, record["pid"])
    record
  rescue Errno::EPERM
    record
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def self.held?(path)
    return false unless File.file?(path)

    File.open(path, "a+") do |probe|
      return true unless probe.flock(File::LOCK_EX | File::LOCK_NB)

      probe.flock(File::LOCK_UN)
    end
    false
  end

  def self.supervised?(path)
    record = holder(path)
    !record.nil? && record["pid"] == Process.ppid && held?(path)
  end

  def self.describe(record)
    return " (holder not published)" unless record

    " (pid #{record['pid']}, #{record['phase']} #{record['state']} since #{record['started']}, " \
      "#{record['worktree']}: #{record['command']})"
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
      raise Busy, "Another native/heavy job is active#{describe(holder(path))}"
    end
    # A lock on a file that was unlinked or replaced meanwhile excludes nobody.
    current = File.stat(path) rescue nil
    unless current && [current.dev, current.ino] == [handle.stat.dev, handle.stat.ino]
      handle.close
      raise Busy, "Native lease file changed during acquisition"
    end
    [handle, false]
  end

  def self.acquire(path, deadline)
    lease(path)
  rescue Busy => error
    raise if monotonic + LEASE_RETRY_SECONDS > deadline

    warn "native_job: #{error.message}; retrying in #{LEASE_RETRY_SECONDS} s"
    sleep LEASE_RETRY_SECONDS
    retry
  end

  # Holds the lease while waiting, so one job queues and the others are refused.
  def self.admit(handle, record, deadline)
    pause = HostLoad.limits.fetch("recheck_seconds")
    loop do
      error = HostLoad.check
      return error if error.nil? || monotonic + pause > deadline

      publish(handle, record.merge("state" => "waiting for admission"))
      warn "native_job: #{error} Rechecking in #{pause} s."
      sleep pause
    end
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

  # The owner's interface keeps priority over a job that runs for minutes.
  # Descendants inherit the value; an already lower priority is kept.
  def self.lower_priority(pid)
    niceness = [HostLoad.limits.fetch("child_niceness"), Process.getpriority(Process::PRIO_PROCESS, 0)].max
    Process.setpriority(Process::PRIO_PGRP, pid, niceness) if niceness.positive?
  rescue SystemCallError
    nil
  end

  def self.recorder(record)
    instance = NativeFlightRecorder::Recorder.new(holder: record)
    instance.start(monotonic)
    instance
  rescue StandardError => error
    warn "native flight recorder unavailable: #{error.class}: #{error.message}"
    nil
  end

  def self.run(phase:, command:, path: LOCK_PATH, build_dir: nil, wait: nil, expose_lease: true)
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
    seconds = (wait || ENV[WAIT_ENV]).to_s
    deadline = monotonic + (seconds.match?(/\A\d+\z/) ? Integer(seconds, 10) : 0)
    handle, inherited = acquire(path, deadline)
    if phase == "build"
      destinations = build_directories(command, build_dir, inherited: inherited)
      error = NativeBuildPreflight.check || MacBuildBudget.check(*destinations)
      if error
        warn error
        return 75
      end
    end
    record = holder_record(phase, command)
    # A nested driver runs inside its owner's admission, priority and record.
    published = !inherited
    publish(handle, record) if published
    services = published && host_services?(path)
    if services
      host_services
      if (error = admit(handle, record, deadline))
        warn error
        return 75
      end
    end
    publish(handle, record.merge("state" => "running")) if published
    signal = nil
    previous = {}
    %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { signal ||= name } }
    environment = { "CARGO_BUILD_JOBS" => build_jobs.to_s, "CMAKE_BUILD_PARALLEL_LEVEL" => build_jobs.to_s }
    options = { pgroup: true }
    if expose_lease
      environment.update(FD_ENV => CHILD_FD.to_s, PATH_ENV => path)
      options[CHILD_FD] = handle
    else
      environment.update(FD_ENV => nil, PATH_ENV => nil)
    end
    environment[BUILD_DIRS_ENV] = JSON.generate(destinations) if destinations
    pid = Process.spawn(environment, [command.first, command.first], *command.drop(1), options)
    if services
      lower_priority(pid)
      flight = recorder(record)
    end
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
      flight&.tick(now)
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
    code = storage_error ? 75 : (signal ? 128 + Signal.list.fetch(signal) : (status.exitstatus || 128 + status.termsig))
    flight&.finish(code)
    code
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
    (publish(handle, nil) rescue nil) if published
    handle&.close unless inherited
  end

  # Who holds the lease and whether a new heavy job would be admitted now.
  def self.status(path)
    path = File.expand_path(path)
    held = held?(path)
    report = { "lease" => { "path" => path, "held" => held, "holder" => (holder(path) if held) } }
    if host_services?(path)
      host_services
      limits = HostLoad.limits
      sample = HostLoad.sample
      report["admission"] = { "limits" => limits, "sample" => sample, "refusal" => HostLoad.refusal(limits, sample) }
      report["flight_recorder"] = File.join(NativeFlightRecorder.directory, NativeFlightRecorder::FILE)
    end
    puts JSON.pretty_generate(report)
    0
  rescue StandardError => error
    warn "native_job: #{error.message}"
    75
  end

  def self.main(arguments)
    options = { path: LOCK_PATH, build_dir: [], wait: nil }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: native_job.rb [--lock-path PATH] [--build-dir PATH] [--wait SECONDS] build|simulator|heavy -- COMMAND [ARGS]\n" \
                    "       native_job.rb status"
      opts.on("--build-dir PATH") { |value| options[:build_dir] << value }
      # Explicit fixture isolation; production callers always use LOCK_PATH.
      opts.on("--lock-path PATH") { |value| options[:path] = value }
      opts.on("--wait SECONDS", Integer) { |value| options[:wait] = value }
    end
    parser.order!(arguments)
    phase = arguments.shift
    return status(options[:path]) if phase == "status" && arguments.empty?

    arguments.shift if arguments.first == "--"
    unless PHASES.include?(phase) && !arguments.empty?
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
