# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "host_load"

# One JSON line per interval while a guarded heavy job runs, so the next host
# incident has load, memory, thermal and process data from before it. Recording
# is best effort: it never delays, fails or outlives the job it describes. A
# line names programs and process IDs only, never arguments or absolute paths.
# The files are readable by their owner alone, and so is a directory created
# here; an existing directory is used as it is.
module NativeFlightRecorder
  ROOT = File.expand_path("..", __dir__)
  DIRECTORY_ENV = "EPUB_NATIVE_FLIGHT_DIR"
  FILE = "flight.jsonl"
  LIMITS = %w[interval_seconds max_file_bytes generations].freeze
  PANIC_REPORTS = %w[/Library/Logs/DiagnosticReports/ProxiedDevice-Bridge/panic-full-*.ips
                     /Library/Logs/DiagnosticReports/panic-full-*.ips
                     /Library/Logs/DiagnosticReports/*.panic].freeze

  def self.limits(path = HostLoad::POLICY)
    value = JSON.parse(File.read(path))["flight_recorder"]
    raise "Missing flight_recorder limits in #{File.basename(path)}" unless value.is_a?(Hash)
    LIMITS.each { |key| raise "Invalid flight_recorder #{key}" unless value[key].is_a?(Integer) && value[key].positive? }
    value
  end

  # Linked worktrees share one recorder beside the main checkout's evidence, so
  # an incident is read from a single file whichever worktree ran the job.
  def self.directory(environment = ENV)
    explicit = environment[DIRECTORY_ENV].to_s
    return File.expand_path(explicit) unless explicit.empty?

    common = HostLoad.capture("git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir", seconds: 3).strip
    main = File.basename(common) == ".git" ? File.dirname(common) : ROOT
    File.join(main, ".reports", "native-flight-recorder")
  rescue StandardError
    File.join(ROOT, ".reports", "native-flight-recorder")
  end

  # One host reading with the warnings it earns, so a line says by itself when
  # a reading went above an advisory threshold; none of them refuses a job.
  def self.reading(sampler: HostLoad.method(:sample), policy: HostLoad.method(:limits))
    sample = sampler.call
    sample.merge("warnings" => HostLoad.notes(policy.call, sample))
  end

  # Bounded storage: the current file plus `generations` rotated ones.
  def self.append(path, record, max_bytes:, generations:)
    line = JSON.generate(record) + "\n"
    if File.size?(path).to_i + line.bytesize > max_bytes
      generations.downto(1) do |index|
        source = index == 1 ? path : "#{path}.#{index - 1}"
        next unless File.exist?(source)

        File.chmod(0o600, source)
        File.rename(source, "#{path}.#{index}")
      end
    end
    File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.chmod(0o600)
      file.write(line)
    end
  end

  # Boot identity for the first line of a job: what the previous shutdown left
  # behind is the baseline a later report is compared with.
  def self.host(capture: HostLoad.method(:capture), reports: PANIC_REPORTS)
    boot = capture.call(HostLoad::SYSCTL, "-n", "kern.boottime")[/sec = (\d+)/, 1]
    events = capture.call("/usr/sbin/ioreg", "-p", "IODeviceTree", "-n", "platform", "-r", "-d", "1")
    panic = Dir.glob(reports).max_by { |path| File.mtime(path) }
    { "boot" => (Time.at(Integer(boot)).utc.iso8601 if boot),
      "startup_power_events" => events[/"StartupPowerEvents" = <([0-9a-f]+)>/, 1],
      "newest_panic_report" => (File.basename(panic) if panic),
      "newest_panic_report_time" => (File.mtime(panic).utc.iso8601 if panic) }
  rescue StandardError => error
    { "host_error" => "#{error.class}: #{error.message}" }
  end

  class Recorder
    attr_reader :path

    # Longest a finishing job waits for a probe that is already running.
    JOIN_SECONDS = 0.2

    def initialize(holder:, directory: NativeFlightRecorder.directory, limits: NativeFlightRecorder.limits,
                   sampler: -> { NativeFlightRecorder.reading },
                   host: -> { NativeFlightRecorder.host }, wall: -> { Time.now.utc })
      @holder = holder.slice("pid", "phase", "program", "task", "worktree", "session")
      @limits = limits
      @sampler = sampler
      @host = host
      @wall = wall
      @path = File.join(directory, FILE)
      @next = nil
      @worker = nil
    end

    # Every host reading happens on a probe thread. The supervisor loop that
    # calls these methods forwards signals and checks storage; slow telemetry on
    # a loaded host must not hold it up.
    def start(now)
      probe("start") { @host.call.merge(sample) }
      schedule(now)
    end

    # Called from the supervisor loop with its monotonic clock.
    def tick(now)
      return unless @next && now >= @next

      schedule(now)
      probe("sample") { sample }
    end

    # Reads nothing from the host, so the job's exit code is not delayed. The
    # last periodic line carries the final readings.
    def finish(exit_status)
      return unless @next

      @next = nil
      # Thread#kill only marks the probe; join it so none outlives the job.
      @worker&.kill&.join(JOIN_SECONDS) unless @worker&.join(JOIN_SECONDS)
      write("end", "exit_status" => exit_status)
    end

    private

    # One probe at a time. A probe still running at the next interval is
    # skipped, never queued.
    def probe(event, &reading)
      return if @worker&.alive?

      @worker = Thread.new { write(event, reading.call) }
      @worker.report_on_exception = false
    end

    # A recorder that could not write stays stopped for the rest of the job.
    def schedule(now)
      @next = @failed ? nil : now + @limits.fetch("interval_seconds")
    end

    def sample
      @sampler.call
    rescue StandardError => error
      { "sample_error" => "#{error.class}: #{error.message}" }
    end

    def write(event, fields)
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      record = { "t" => @wall.call.iso8601, "event" => event, "holder" => @holder }.merge(fields)
      NativeFlightRecorder.append(@path, record, max_bytes: @limits.fetch("max_file_bytes"),
                                                 generations: @limits.fetch("generations"))
    rescue StandardError => error
      warn "native flight recorder stopped: #{error.class}: #{error.message}" unless @failed
      @failed = true
      @next = nil
    end
  end
end
