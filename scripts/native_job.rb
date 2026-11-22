#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "json"
require "rbconfig"
require "etc"
require "time"
require_relative "mac_build_budget"

# One lease serializes jobs that write shared build output (DerivedData, Cargo
# targets, ONNX Runtime trees). Descendants receive the actual open file
# description, never an environment-only permission to skip coordination.
# Host load, memory, thermal, storage and Simulator state are advisory only:
# Pietro removed every host guard on 2026-11-22, so they are logged and never
# refuse, delay or stop a job.
module NativeJob
  # One absolute path for every worktree and session. /tmp is emptied at reboot;
  # the next job recreates the file, and no holder can survive a reboot.
  LOCK_PATH = "/tmp/epub2mp3.heavy-job.lock"
  # Host notes, priority and flight recording belong to the one real host
  # lease. A fixture lease (an explicit --lock-path, or this script copied with
  # LOCK_PATH rewritten) exercises only the lease protocol, so host load never
  # leaks into host tests and those copies need no further files. This value is
  # deliberately not spelled like LOCK_PATH.
  HOST_LEASE = File.join("/tmp", "epub2mp3.heavy-job.lock")
  CHILD_FD = 9
  FD_ENV = "EPUB_NATIVE_LEASE_FD"
  PATH_ENV = "EPUB_NATIVE_LEASE_PATH"
  BUILD_DIRS_ENV = "EPUB_NATIVE_BUILD_DIRECTORIES"
  # Queue instead of polling: seconds to wait for the lease.
  WAIT_ENV = "EPUB_NATIVE_WAIT_SECONDS"
  LEASE_RETRY_SECONDS = 5
  PHASES = %w[build simulator heavy].freeze
  SESSION_KEYS = { "claude" => "CLAUDE_CODE_SESSION_ID", "herdr" => "HERDR_PANE_ID", "agent" => "AI_AGENT" }.freeze
  # GitHub-hosted runners are disposable VMs; the owner approved parallel
  # Cargo/CMake there (2026-11-19). Every other host, including this Mac,
  # defaults to one compiler job. This is a default only: an explicit -j flag
  # is never refused.
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

  # Host notes, priority and the flight recorder, loaded on demand so a fixture
  # copy of this script stays self-contained.
  def self.host_services
    require_relative "native_host_services"
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
  # lease without opening a second independent lock.
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
    MacBuildBudget.advise(*destinations)
    nil
  rescue StandardError => error
    warn "native_job: #{error.message}"
    exit 75
  end

  # Full host suites fork for minutes and are a heavy class on this Mac. They
  # run under the host lease and keep its open file description, but see no
  # variable announcing it, so every suite keeps its own fixture isolation.
  # Other hosts, including hosted CI, are unchanged.
  def self.heavy_entrypoint(file, arguments = [], path: LOCK_PATH)
    return nil unless host_services?(path)
    if supervised?(path)
      [FD_ENV, PATH_ENV].each { |name| ENV.delete(name) }
      return nil
    end
    exit run(phase: "heavy", command: [RbConfig.ruby, File.expand_path(file), *arguments], path: path, expose_lease: false)
  end

  # Names only: the program, the mise task and the checkout directory. Never
  # the arguments or an absolute path, which can carry a credential or a user
  # name into a file that other tools read. A value that is not a plain name
  # is left out.
  def self.holder_record(phase, command)
    name = ->(value) { value.to_s[/\A[\w.:@+-]{1,80}\z/] }
    session = SESSION_KEYS.filter_map { |label, key| "#{label}=#{name.call(ENV[key])}" if name.call(ENV[key]) }.join(" ")
    { "pid" => Process.pid, "phase" => phase, "state" => "starting",
      "program" => name.call(File.basename(command.first.to_s)) || "unnamed",
      "task" => name.call(ENV["MISE_TASK_NAME"]), "started" => Time.now.utc.iso8601,
      "worktree" => name.call(File.basename(File.expand_path("..", __dir__))) || "unnamed", "session" => session }
  end

  # The lease file names its holder while held and is empty otherwise. One
  # write covers the previous text before the tail is cut, so one read never
  # finds an empty or half-written record (JSON ignores the padding).
  def self.publish(handle, record)
    text = record ? JSON.generate(record) + "\n" : ""
    handle.pwrite(text + (" " * [handle.size - text.bytesize, 0].max), 0) unless text.empty?
    handle.truncate(text.bytesize)
  end

  def self.alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::EPERM
    true
  rescue SystemCallError, RangeError
    false
  end

  # One read call: the record is rewritten in place, and a second call could
  # join an older record to the tail of a newer one. Repeated if a rewrite
  # still shows through.
  def self.read_record(path, attempts = 3)
    JSON.parse(File.open(path) { |file| file.sysread(65_536) })
  rescue JSON::ParserError
    retry if (attempts -= 1).positive?
  rescue EOFError, SystemCallError
    nil
  end

  # Advisory and read-only: it never takes the lock, so asking cannot refuse a
  # real job. A holder older than this record (an earlier checkout, a descendant
  # left behind by a finished job) holds the lease without one.
  def self.holder(path)
    record = read_record(path)
    return nil unless record.is_a?(Hash) && record["pid"].is_a?(Integer)
    return record if alive?(record["pid"])

    # The supervisor died without releasing: its job still holds the lease.
    child = record["child"]
    record.merge("state" => "orphaned, supervisor gone") if child.is_a?(Integer) && child > 1 && alive?(-child)
  end

  # Proof that a descriptor is the lease itself: an independently opened
  # descriptor is excluded while this open file description can reassert the
  # lock. Both are required to reject a stale descriptor or one that merely
  # points at the same file.
  def self.inherited_lease(descriptor, path)
    handle = File.for_fd(descriptor, autoclose: false)
    stat = handle.stat
    expected = File.stat(path)
    raise "Inherited native lease points to another file" unless stat.file? && [stat.dev, stat.ino] == [expected.dev, expected.ino]
    File.open(path, "a+") do |probe|
      if probe.flock(File::LOCK_EX | File::LOCK_NB)
        probe.flock(File::LOCK_UN)
        raise "Inherited native lease is no longer held"
      end
    end
    raise "Inherited native lease does not own the lock" unless handle.flock(File::LOCK_EX | File::LOCK_NB)
    handle
  end

  # True inside a job of the current holder: this process inherited the lease's
  # own open file description, which neither an environment variable nor the
  # holder record can stand in for.
  def self.supervised?(path)
    inherited_lease(CHILD_FD, path)
    true
  rescue StandardError
    false
  end

  # Who to look at when the lease is busy: the published holder and, on the
  # host lease, every process that really keeps the file open. That listing
  # scans the process table, so a waiting job asks for it once, not per retry.
  def self.describe(path, listing: true)
    record = holder(path)
    named = record.to_h.values_at("program", "task").compact.join(" in ")
    parts = [if record
               "pid #{record['pid']}, #{record['phase']} #{record['state']} since #{record['started']}, " \
                 "#{record['worktree']}#{": #{named}" unless named.empty?}"
             else
               "no holder record: an older checkout or a process left behind by an earlier job holds it"
             end]
    if listing && host_services?(path)
      host_services
      parts << lease_users(path)
    end
    " (#{parts.compact.join('; ')})"
  end

  def self.lease(path, listing: true)
    inherited = ENV[FD_ENV]
    if inherited || ENV[PATH_ENV]
      raise "Invalid inherited native lease" unless inherited&.match?(/\A\d+\z/) && ENV[PATH_ENV] == path
      return [inherited_lease(Integer(inherited), path), true]
    end
    handle = File.open(path, File::RDWR | File::CREAT, 0o600)
    unless handle.flock(File::LOCK_EX | File::LOCK_NB)
      handle.close
      raise Busy, "Another native/heavy job is active#{describe(path, listing: listing)}"
    end
    handle.chmod(0o600) rescue nil
    # A lock on a file that was unlinked or replaced meanwhile excludes nobody.
    current = File.stat(path) rescue nil
    unless current && [current.dev, current.ino] == [handle.stat.dev, handle.stat.ino]
      handle.close
      raise Busy, "Native lease file changed during acquisition"
    end
    [handle, false]
  end

  # Whole seconds only: "15m" or " 900" must fail instead of silently meaning
  # "do not wait". Nil when the caller asked for nothing.
  def self.wait_seconds(explicit)
    value = explicit.nil? ? ENV[WAIT_ENV].to_s : explicit.to_s
    return nil if value.empty?
    raise ArgumentError, "Invalid wait #{value.inspect}: give whole seconds, for example 900" unless value.match?(/\A\d+\z/)

    Integer(value, 10)
  end

  # A wait shorter than the retry interval still retries once, at its end. The
  # first refusal and the final one, made once the wait is over, list the
  # processes that keep the lease open.
  def self.acquire(path, deadline, listing = true)
    final = deadline <= monotonic
    lease(path, listing: listing || final)
  rescue Busy => error
    raise if final

    pause = [[deadline - monotonic, 0.01].max, LEASE_RETRY_SECONDS].min
    warn "native_job: #{error.message}; retrying in #{pause.ceil} s"
    sleep pause
    listing = false
    retry
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

  def self.run(phase:, command:, path: LOCK_PATH, build_dir: nil, wait: nil, expose_lease: true)
    path = File.expand_path(path)
    explicit = wait_seconds(wait)
    deadline = monotonic + (explicit || 0)
    handle, inherited = acquire(path, deadline)
    if phase == "build"
      destinations = build_directories(command, build_dir, inherited: inherited)
      MacBuildBudget.advise(*destinations)
    end
    record = holder_record(phase, command)
    # A nested driver runs inside its owner's priority and record.
    published = !inherited
    publish(handle, record) if published
    services = published && host_services?(path)
    if services
      host_services
      advise
      flight = recorder(record)
    end
    argv = services ? prioritized(command) : command
    signal = nil
    previous = {}
    %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { signal ||= name } }
    environment = { "CARGO_BUILD_JOBS" => build_jobs.to_s, "CMAKE_BUILD_PARALLEL_LEVEL" => build_jobs.to_s }
    # Every job keeps the lease's open file description: the lock then lasts as
    # long as the load does, even if this supervisor is killed. A suite that
    # must not join the lease gets the description without the variables.
    lease_variables = expose_lease ? { FD_ENV => CHILD_FD.to_s, PATH_ENV => path } : { FD_ENV => nil, PATH_ENV => nil }
    environment.update(lease_variables)
    environment[BUILD_DIRS_ENV] = JSON.generate(destinations) if destinations
    pid = Process.spawn(environment, [argv.first, argv.first], *argv.drop(1), CHILD_FD => handle, pgroup: true)
    publish(handle, record.merge("state" => "running", "child" => pid)) if published
    flight&.start(monotonic)
    status = nil
    cancelled_at = nil
    until status
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
    code = signal ? 128 + Signal.list.fetch(signal) : (status.exitstatus || 128 + status.termsig)
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

  # Who holds the lease and the current host readings. Read-only: it never takes the lock. On the host lease it also lists every
  # process that keeps the lease file open, with or without a holder record.
  def self.status(path)
    path = File.expand_path(path)
    record = holder(path)
    report = { "lease" => { "path" => path, "held" => !record.nil?, "holder" => record } }
    if host_services?(path)
      host_services
      report["lease"].update(lease_usage(path, record))
      report["host"] = host_report
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
      opts.on("--wait SECONDS") { |value| options[:wait] = value }
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
