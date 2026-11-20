# frozen_string_literal: true

require_relative "host_load"
require_relative "native_flight_recorder"

# The host-wide half of the native supervisor: admission, priority and the
# flight recorder. NativeJob loads it only for the real host lease, so a
# fixture copy of native_job.rb needs none of these files.
module NativeJob
  NICE = "/usr/bin/nice"

  # Holds the lease while waiting, so one job queues and the others are refused.
  def self.admit(handle, record, deadline)
    interval = HostLoad.limits.fetch("recheck_seconds")
    loop do
      error = HostLoad.check
      remaining = deadline - monotonic
      return error if error.nil? || !remaining.positive?

      pause = [remaining, interval].min
      publish(handle, record.merge("state" => "waiting for admission"))
      warn "native_job: #{error} Rechecking in #{pause.ceil} s."
      sleep pause
    end
  end

  def self.resolvable?(program)
    candidates = program.include?("/") ? [program] : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, program) }
    candidates.any? { |candidate| File.file?(candidate) && File.executable?(candidate) }
  end

  # The owner's interface keeps priority over a job that runs for minutes.
  # `nice` lowers the priority and then becomes the command in the same process,
  # so the job never runs at normal priority and its PID and group are unchanged.
  # Descendants inherit the value; an already lower priority is kept.
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

  def self.recorder(record)
    instance = NativeFlightRecorder::Recorder.new(holder: record)
    instance.start(monotonic)
    instance
  rescue StandardError => error
    warn "native flight recorder unavailable: #{error.class}: #{error.message}"
    nil
  end
end
