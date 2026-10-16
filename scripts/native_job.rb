#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "rbconfig"
require_relative "native_build_preflight"

# One lease spans inspection and execution. Descendants receive the actual open
# file description, never an environment-only permission to skip coordination.
module NativeJob
  LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
  CHILD_FD = 9
  FD_ENV = "EPUB_NATIVE_LEASE_FD"
  PATH_ENV = "EPUB_NATIVE_LEASE_PATH"

  # Ruby build drivers call this before preparation or compiler work. The first
  # invocation becomes a supervised child; that child validates its real inherited
  # lease and rechecks host state without opening a second independent lock.
  def self.build_entrypoint(file, arguments = [])
    unless ENV[FD_ENV] || ENV[PATH_ENV]
      exit run(phase: "build", command: [RbConfig.ruby, File.expand_path(file), *arguments])
    end
    lease(LOCK_PATH)
    error = NativeBuildPreflight.check
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

  def self.run(phase:, command:, path: LOCK_PATH)
    # Recurrent IGGuC.cpp:2913 panics occurred inside SimMetalHost on this
    # Intel host. A lease cannot make the GPU driver safe. Keep Simulator
    # execution quarantined; neither inherited leases nor environment flags
    # authorize another attempt. Use physical-device verification instead.
    if phase == "simulator" && RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
      warn "Intel Simulator execution is quarantined after recurrent IGGuC/SimMetalHost kernel panics. Use physical-device verification; do not retry or boot Simulator."
      return 75
    end
    path = File.expand_path(path)
    handle, inherited = lease(path)
    if phase == "build"
      error = NativeBuildPreflight.check
      if error
        warn error
        return 75
      end
    end
    signal = nil
    previous = {}
    %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { signal ||= name } }
    environment = { FD_ENV => CHILD_FD.to_s, PATH_ENV => path }
    pid = Process.spawn(environment, [command.first, command.first], *command.drop(1), CHILD_FD => handle, pgroup: true)
    status = nil
    cancelled_at = nil
    until status
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
    signal ? 128 + Signal.list.fetch(signal) : (status.exitstatus || 128 + status.termsig)
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
