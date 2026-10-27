#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "rbconfig"
require_relative "native_build_preflight"
require_relative "mac_build_budget"

# One lease spans inspection and execution. Descendants receive the actual open
# file description, never an environment-only permission to skip coordination.
module NativeJob
  LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
  CHILD_FD = 9
  FD_ENV = "EPUB_NATIVE_LEASE_FD"
  PATH_ENV = "EPUB_NATIVE_LEASE_PATH"

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
  def self.build_entrypoint(file, arguments = [])
    unless ENV[FD_ENV] || ENV[PATH_ENV]
      exit run(phase: "build", command: [RbConfig.ruby, File.expand_path(file), *arguments])
    end
    lease(LOCK_PATH)
    error = NativeBuildPreflight.check || MacBuildBudget.check
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

  def self.process_snapshot
    output, status = Open3.capture2("ps", "-axo", "pid=,ppid=,lstart=")
    raise "Cannot inspect native process ownership" unless status.success?
    output.lines.filter_map do |line|
      child, parent, birth = line.strip.split(/\s+/, 3)
      [Integer(child), { parent: Integer(parent), birth: birth }] if birth
    end.to_h
  end

  def self.same_session?(child, leader)
    Process.respond_to?(:getsid) && Process.getsid(child) == leader
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def self.owned_processes(pid)
    snapshot = process_snapshot
    # The isolated session survives its leader. Foundation-created process
    # groups therefore remain identifiable even after an ordinary leader failure.
    owned = snapshot.select { |child, _| same_session?(child, pid) }
    owned[pid] = snapshot[pid] if snapshot[pid]
    parents = [pid]
    until parents.empty?
      children = snapshot.select { |child, row| parents.include?(row[:parent]) }
      children.reject! { |child, _| child == pid }
      break if children.empty?
      owned.merge!(children)
      parents = children.keys
    end
    owned
  end

  def self.signal_descendants(owned, signal)
    return if owned.empty?
    current = process_snapshot
    owned.each do |pid, row|
      # A recycled PID must never authorize signalling an unrelated process.
      next unless current[pid]&.fetch(:birth) == row[:birth]
      Process.kill(signal, pid) rescue Errno::ESRCH
    end
  end

  def self.signal_owned(pid, owned, signal)
    signal_descendants(owned, signal)
  rescue StandardError => error
    warn "native_job: cleanup inspection failed: #{error.message}"
    # A known PID can still be checked against the kernel-owned isolated
    # session when ps is unavailable. Another session is never signalled.
    owned.each_key do |child|
      next unless same_session?(child, pid)
      Process.kill(signal, child) rescue Errno::ESRCH
    end
  ensure
    begin
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def self.stop_group(pid, owned = {})
    begin
      owned = owned_processes(pid).merge(owned)
    rescue StandardError => error
      warn "native_job: cleanup inspection failed: #{error.message}"
    end
    signal_owned(pid, owned, "TERM")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.5
    loop do
      group_alive = begin
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
      current = begin
        owned.empty? ? {} : process_snapshot
      rescue StandardError => error
        warn "native_job: cleanup inspection failed: #{error.message}"
        break # Force the known group/session to stop even without inspection.
      end
      descendants_alive = owned.any? { |child, row| current[child]&.fetch(:birth) == row[:birth] }
      break unless group_alive || descendants_alive
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    signal_owned(pid, owned, "KILL")
  end

  def self.spawn_owned(environment, command, handle)
    unless Process.respond_to?(:fork)
      return Process.spawn(environment, [command.first, command.first], *command.drop(1), CHILD_FD => handle, pgroup: true)
    end
    Process.fork do
      %w[INT TERM HUP].each { |name| Signal.trap(name, "DEFAULT") }
      Process.setsid
      exec(environment, [command.first, command.first], *command.drop(1), CHILD_FD => handle)
    rescue StandardError => error
      warn "native_job: #{error.message}"
      exit! 75
    end
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
      return "Mac compilation requires exactly one job" unless number == "1"
    end
    nil
  end

  def self.run(phase:, command:, path: LOCK_PATH)
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
      error = NativeBuildPreflight.check || MacBuildBudget.check
      if error
        warn error
        return 75
      end
    end
    signal = nil
    previous = {}
    %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { signal ||= name } }
    environment = { FD_ENV => CHILD_FD.to_s, PATH_ENV => path,
                    "CARGO_BUILD_JOBS" => "1", "CMAKE_BUILD_PARALLEL_LEVEL" => "1" }
    process_snapshot # Refuse before launch if ownership inspection is unavailable.
    pid = spawn_owned(environment, command, handle)
    status = nil
    cancelled_at = nil
    storage_error = nil
    owned_descendants = {}
    storage_interval = MacBuildBudget.interval
    next_storage_check = Process.clock_gettime(Process::CLOCK_MONOTONIC) + storage_interval
    until status
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if phase == "build" && now >= next_storage_check && !storage_error
        storage_error = MacBuildBudget.check
        if storage_error
          warn storage_error
          signal ||= "TERM"
        end
        next_storage_check = now + storage_interval
      end
      if signal && !cancelled_at
        # Foundation Process and other launchers can give descendants separate
        # process groups. Capture ancestry while the leader is still alive.
        owned_descendants = owned_processes(pid)
        signal_owned(pid, owned_descendants, signal)
        cancelled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elsif cancelled_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - cancelled_at > 2
        signal_owned(pid, owned_descendants, "KILL")
      end
      result = Process.waitpid2(pid, Process::WNOHANG)
      status = result&.last
      sleep 0.02 unless status
    end
    # The process leader may exit before a descendant that ignored termination.
    if signal || !status.success?
      # Give nested supervisors a chance to forward termination to their own group
      # before killing descendants that ignored it.
      stop_group(pid, owned_descendants)
    end
    storage_error ? 75 : (signal ? 128 + Signal.list.fetch(signal) : (status.exitstatus || 128 + status.termsig))
  rescue StandardError => error
    warn "native_job: #{error.message}"
    75
  ensure
    if pid && !status
      # Unexpected host-side failures must not leave work running without its lease.
      stop_group(pid, owned_descendants || {})
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    previous&.each { |name, handler| Signal.trap(name, handler) }
    handle&.close unless inherited
  end

  def self.main(arguments)
    options = { path: LOCK_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: native_job.rb [--lock-path PATH] build|simulator -- COMMAND [ARGS]"
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
