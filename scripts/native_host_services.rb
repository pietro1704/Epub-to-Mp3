# frozen_string_literal: true

require_relative "host_load"
require_relative "native_flight_recorder"

# The host-wide half of the native supervisor: advisory notes, priority, the flight
# recorder and the list of processes that keep the lease file open. NativeJob
# loads it only for the real host lease, so a fixture copy of native_job.rb
# needs none of these files.
module NativeJob
  NICE = "/usr/bin/nice"
  LSOF = "/usr/sbin/lsof"

  # One reading when the job starts, reported as information. Nothing here
  # refuses, delays or stops a job; the flight log keeps the readings.
  def self.advise
    notes = HostLoad.assess
    warn "native_job: advisory, not a refusal: #{notes.join('; ')}. The flight log records it." unless notes.empty?
    notes
  end

  # Every process that has the lease file open, whoever started it: what really
  # keeps the lease when no record names a holder (a browser or daemon left
  # behind by a finished job). Read-only; process IDs and program names only,
  # and only processes this user may inspect. Raises when the processes cannot
  # be listed: unknown is not "nobody".
  def self.lease_holders(path, proc_root: "/proc")
    target = File.stat(path)
    pids = if File.directory?(File.join(proc_root, "self/fd"))
             # Linux: one link per open descriptor of every process.
             Dir.glob("[0-9]*/fd/*", base: proc_root).filter_map do |entry|
               stat = File.stat(File.join(proc_root, entry)) rescue next
               pid = entry[/\A(\d+)\//, 1]
               Integer(pid) if pid && [stat.dev, stat.ino] == [target.dev, target.ino]
             end
           else
             # lsof exits 1 when no process has the file open.
             HostLoad.capture(LSOF, "-t", path, tolerate_failure: true).split.map { |pid| Integer(pid) }
           end
    pids = pids.uniq - [Process.pid]
    return [] if pids.empty?

    HostLoad.capture(HostLoad::PS, "-o", "pid=", "-o", "comm=", "-p", pids.join(","), tolerate_failure: true).lines.filter_map do |line|
      pid, command = line.strip.split(/\s+/, 2)
      "#{pid} #{File.basename(command)}" if command
    end
  end

  # For a busy lease: the processes to look at, or why they could not be listed.
  def self.lease_users(path)
    holders = lease_holders(path)
    return nil if holders.empty?

    more = holders.length - 6
    "lease file open in #{holders.first(6).join(', ')}#{" and #{more} more" if more.positive?}"
  rescue StandardError => error
    "the processes that keep the lease file open could not be listed (#{error.class}: #{error.message})"
  end

  # For status. Held means a published holder or any process that keeps the
  # file open; with neither a record nor a listing it is unknown, not false.
  def self.lease_usage(path, record)
    holders = File.file?(path) ? lease_holders(path) : []
    { "held" => !record.nil? || !holders.empty?, "open_in" => holders }
  rescue StandardError => error
    { "held" => (true if record), "open_in" => nil, "open_in_error" => "#{error.class}: #{error.message}" }
  end

  # For status: the thresholds, one reading and the notes it earns.
  def self.host_report
    limits = HostLoad.limits
    sample = HostLoad.sample
    { "limits" => limits, "sample" => sample, "notes" => HostLoad.notes(limits, sample) }
  end

  def self.resolvable?(program)
    candidates = program.include?("/") ? [program] : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, program) }
    candidates.any? { |candidate| File.file?(candidate) && File.executable?(candidate) }
  end

  # The owner's interface keeps priority over a job that runs for minutes.
  # `nice` lowers the priority and then becomes the command in the same process,
  # so the job never runs at normal priority and its PID and group are unchanged.
  # Descendants inherit the value. A job that already runs at that priority or
  # lower needs no change, so nothing is done and nothing is reported.
  def self.prioritized(command)
    increment = HostLoad.limits.fetch("child_niceness") - Process.getpriority(Process::PRIO_PROCESS, 0)
    return command unless increment.positive?
    unless File.executable?(NICE)
      warn "native_job: #{NICE} is unavailable; this job runs at normal priority"
      return command
    end
    # Keep the supervisor's own refusal for a program that does not exist.
    raise Errno::ENOENT, command.first unless resolvable?(command.first)

    [NICE, "-n", increment.to_s, *command]
  end

  # Built before the job starts: finding the shared evidence directory asks git,
  # which must not run on the supervisor's loop once a child exists.
  def self.recorder(record)
    NativeFlightRecorder::Recorder.new(holder: record)
  rescue StandardError => error
    warn "native flight recorder unavailable: #{error.class}: #{error.message}"
    nil
  end
end
