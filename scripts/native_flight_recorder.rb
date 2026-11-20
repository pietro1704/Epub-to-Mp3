# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "time"
require_relative "host_load"

# One JSON line per interval while a guarded heavy job runs, so the next host
# incident has load, memory, thermal and process data from before it. Recording
# is best effort: it never delays, fails or outlives the job it describes.
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

    common, status = Open3.capture2("git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir",
                                    err: File::NULL)
    common = common.strip
    main = status.success? && File.basename(common) == ".git" ? File.dirname(common) : ROOT
    File.join(main, ".reports", "native-flight-recorder")
  rescue SystemCallError
    File.join(ROOT, ".reports", "native-flight-recorder")
  end

  # Bounded storage: the current file plus `generations` rotated ones.
  def self.append(path, record, max_bytes:, generations:)
    line = JSON.generate(record) + "\n"
    if File.size?(path).to_i + line.bytesize > max_bytes
      generations.downto(1) do |index|
        source = index == 1 ? path : "#{path}.#{index - 1}"
        File.rename(source, "#{path}.#{index}") if File.exist?(source)
      end
    end
    File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) { |file| file.write(line) }
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

    def initialize(holder:, directory: NativeFlightRecorder.directory, limits: NativeFlightRecorder.limits,
                   sampler: -> { HostLoad.sample },
                   host: -> { NativeFlightRecorder.host }, wall: -> { Time.now.utc })
      @holder = holder.slice("pid", "phase", "command", "worktree", "session")
      @limits = limits
      @sampler = sampler
      @host = host
      @wall = wall
      @path = File.join(directory, FILE)
      @next = nil
    end

    def start(now)
      write("start", @host.call.merge(sample))
      schedule(now)
    end

    # Called from the supervisor loop with its monotonic clock.
    def tick(now)
      return unless @next && now >= @next

      write("sample", sample)
      schedule(now)
    end

    def finish(exit_status)
      return unless @next

      write("end", sample.merge("exit_status" => exit_status))
      @next = nil
    end

    private

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
      FileUtils.mkdir_p(File.dirname(@path))
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
