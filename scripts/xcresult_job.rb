#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "tmpdir"

# xcresulttool can create its SQLite database during a read. Coordinate readers
# by canonical bundle identity rather than serializing unrelated result bundles.
module XCResultJob
  LOCK_FD = 9

  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.validate(bundle, command)
    canonical = File.realpath(bundle)
    raise ArgumentError, "bundle must be an existing .xcresult directory" unless File.directory?(canonical) && canonical.end_with?(".xcresult")
    unless command.length >= 3 && File.basename(command.first) == "xcrun" && command[1] == "xcresulttool"
      raise ArgumentError, "command must be xcrun xcresulttool with an explicit --path"
    end
    paths = []
    command.each_with_index do |argument, index|
      paths << command[index + 1] if argument == "--path"
      paths << argument.delete_prefix("--path=") if argument.start_with?("--path=")
    end
    raise ArgumentError, "every --path must name the guarded bundle" if paths.empty? || paths.any? { |path| !path || File.realpath(path) != canonical }
    canonical
  rescue Errno::ENOENT, Errno::ENOTDIR => error
    raise ArgumentError, error.message
  end

  def self.lock_path(bundle)
    directory = File.join(Dir.tmpdir, "epubtomp3-xcresult-#{Process.uid}")
    begin
      Dir.mkdir(directory, 0o700)
    rescue Errno::EEXIST
      # Check an existing namespace without following a substituted symlink.
    end
    stat = File.lstat(directory)
    raise "unsafe xcresult lock directory" unless stat.directory? && stat.uid == Process.uid && stat.mode & 0o077 == 0
    File.join(directory, "#{Digest::SHA256.hexdigest(bundle)}.lock")
  end

  def self.signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def self.finish_group(pid)
    Process.kill(0, -pid)
    signal_group(pid, "TERM")
    deadline = clock + 1
    loop do
      Process.kill(0, -pid)
      break if clock >= deadline
      sleep 0.01
    end
    signal_group(pid, "KILL")
  rescue Errno::ESRCH
    nil
  end

  def self.run(bundle, command, timeout: ENV.fetch("XCRESULT_LOCK_TIMEOUT_SECONDS", "30"))
    status = nil
    canonical = validate(bundle, command)
    # Resolve aliases before waiting; a symlink retargeted during contention
    # must not redirect the operation to an unguarded second bundle.
    command = command.each_with_index.map do |argument, index|
      if command[index - 1] == "--path" && index.positive?
        canonical
      elsif argument.start_with?("--path=")
        "--path=#{canonical}"
      else
        argument
      end
    end
    timeout = Float(timeout)
    raise ArgumentError, "lock timeout must be finite, positive and at most 60 seconds" unless timeout.finite? && timeout.positive? && timeout <= 60
    cancelled = nil
    handlers = {}
    %w[INT TERM HUP].each { |name| handlers[name] = Signal.trap(name) { cancelled ||= name } }
    lock = File.open(lock_path(canonical), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
    deadline = clock + timeout
    waiting = false
    until lock.flock(File::LOCK_EX | File::LOCK_NB)
      unless waiting
        warn "xcresult_job: waiting for bundle lease: #{canonical}"
        waiting = true
      end
      return 128 + Signal.list.fetch(cancelled) if cancelled
      raise "timed out waiting for xcresult bundle lease" if clock >= deadline
      sleep 0.02
    end
    return 128 + Signal.list.fetch(cancelled) if cancelled
    # Pass the lease to the tool so abrupt supervisor death cannot unlock an
    # operation that is still running. Arguments never pass through a shell.
    pid = Process.spawn([command.first, command.first], *command.drop(1), LOCK_FD => lock, pgroup: true)
    stopping_at = nil
    killed = false
    loop do
      result = Process.waitpid2(pid, Process::WNOHANG)
      if result
        status = result.last
        finish_group(pid)
        return cancelled ? 128 + Signal.list.fetch(cancelled) : status.exitstatus || 128 + status.termsig
      end
      if cancelled && !stopping_at
        signal_group(pid, cancelled)
        stopping_at = clock
      elsif stopping_at && !killed && clock - stopping_at >= 1
        signal_group(pid, "KILL")
        killed = true
      end
      sleep 0.01
    end
  rescue ArgumentError => error
    warn "xcresult_job: #{error.message}"
    2
  rescue StandardError => error
    warn "xcresult_job: #{error.message}"
    75
  ensure
    if pid && !status
      finish_group(pid)
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    lock&.close
    handlers&.each { |name, handler| Signal.trap(name, handler) }
  end

  def self.main(arguments)
    bundle = arguments.shift
    unless bundle && arguments.shift == "--" && !arguments.empty?
      warn "Usage: xcresult_job.rb BUNDLE -- xcrun xcresulttool ... --path BUNDLE"
      return 2
    end
    run(bundle, arguments)
  end
end

exit XCResultJob.main(ARGV) if $PROGRAM_NAME == __FILE__
