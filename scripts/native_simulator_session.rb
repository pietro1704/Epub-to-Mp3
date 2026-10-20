#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "rexml/document"
require "rbconfig"
require "tempfile"
require_relative "native_job"

# Linux-only injected process contracts. There is deliberately no Apple backend.
# File/XML identity validation is not Mach-O, signing or native-app acceptance.
module NativeSimulatorSession
  class Stop < StandardError
    attr_reader :fatal
    def initialize(message, fatal: false)
      super(message)
      @fatal = fatal
    end
  end

  class ResourceDenied < Stop; end

  def self.now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  class Plan
    DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-SE"
    RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-15-5"
    XCODE = "/Applications/Xcode-16.4.0.app/Contents/Developer"
    CHUNK_BYTES = 65_536
    VALIDATION_SECONDS = 5.0
    # The test host is still a regular-file fixture, not an admitted native app.
    FILE_LIMITS = { "plan" => 65_536, "xctestrun" => 4 * 1024**2,
                    "source" => 1024**2, "monitor" => 256 * 1024,
                    "test_host" => 4 * 1024**2 }.freeze
    TOTAL_BYTES = FILE_LIMITS.values.sum
    attr_reader :data

    def self.checkpoint!(deadline, progress)
      raise Stop, "Artifact validation deadline exceeded" if NativeSimulatorSession.now >= deadline
      progress&.call
      raise Stop, "Artifact validation deadline exceeded" if NativeSimulatorSession.now >= deadline
    end

    def self.metadata(stat)
      [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime]
    end

    def self.read_identity(path, limit:, deadline:, progress: nil, capture: false)
      checkpoint!(deadline, progress)
      expanded = File.expand_path(path)
      raise Stop, "Identity path must be canonical" unless File.realpath(expanded) == expanded
      before = File.lstat(expanded)
      raise Stop, "Identity must be a regular file" unless before.file?
      raise Stop, "Artifact exceeds size limit" if before.size > limit
      unless File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)
        raise Stop, "Nonblocking no-follow artifact reads unavailable"
      end
      checkpoint!(deadline, progress)
      digest = Digest::SHA256.new
      bytes = 0
      contents = +"" if capture
      File.open(expanded, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        opened = file.stat
        unless opened.file? && metadata(opened) == metadata(before)
          raise Stop, "Identity changed before reading"
        end
        loop do
          checkpoint!(deadline, progress)
          chunk = file.read([CHUNK_BYTES, limit + 1 - bytes].min)
          checkpoint!(deadline, progress)
          break unless chunk
          bytes += chunk.bytesize
          raise Stop, "Artifact exceeds size limit" if bytes > limit
          digest.update(chunk)
          contents << chunk if capture
        end
        checkpoint!(deadline, progress)
        unless bytes == before.size && metadata(file.stat) == metadata(before) &&
               File.realpath(expanded) == expanded && metadata(File.lstat(expanded)) == metadata(before)
          raise Stop, "Identity changed while hashing"
        end
      end
      [[expanded, *metadata(before), digest.hexdigest], contents]
    rescue SystemCallError => error
      raise Stop, "Cannot read artifact identity (#{error.class})"
    end

    def initialize(path)
      @path = File.expand_path(path)
      deadline = NativeSimulatorSession.now + VALIDATION_SECONDS
      @plan_identity, contents = self.class.read_identity(@path, limit: FILE_LIMITS.fetch("plan"), deadline: deadline, capture: true)
      @data = JSON.parse(contents, freeze: true)
      expected = %w[schema_version device xcode_path xcode_version source_revision source_root files tests duration_seconds phase_timeout_seconds cleanup_timeout_seconds]
      raise Stop, "Unknown or missing session fields" unless @data.is_a?(Hash) && @data.keys.sort == expected.sort
      target = @data.fetch("device")
      unless @data["schema_version"] == 1 && target.is_a?(Hash) && target.keys.sort == %w[uuid name device_type runtime].sort &&
             target["uuid"].is_a?(String) && target["uuid"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i) &&
             target["name"] == "iPhone SE" && target["device_type"] == DEVICE_TYPE && target["runtime"] == RUNTIME &&
             @data["xcode_path"] == XCODE && @data["xcode_version"] == "16.4" &&
             @data["source_revision"].is_a?(String) && @data["source_revision"].match?(/\A[0-9a-f]{40}\z/)
        raise Stop, "Session requires exact SE1/iOS15.5/Xcode16.4 identity"
      end
      %w[duration_seconds phase_timeout_seconds cleanup_timeout_seconds].each do |key|
        value = @data[key]
        raise Stop, "Invalid session deadline" unless value.is_a?(Numeric) && value.finite? && value.positive? && value <= 300
      end
      unless @data["cleanup_timeout_seconds"] < @data["duration_seconds"] && @data["phase_timeout_seconds"] <= @data["duration_seconds"]
        raise Stop, "Cleanup requires a reserved session budget"
      end
      tests = @data["tests"]
      unless tests.is_a?(Array) && tests.length.between?(1, 20) && tests.uniq == tests &&
             tests.all? { |test| test.is_a?(String) && test.match?(/\AEpubToMp3(?:UI)?Tests\/[A-Za-z_]\w*(?:\/[A-Za-z_]\w*)?\z/) }
        raise Stop, "Session requires explicit native test identifiers"
      end
      root = @data["source_root"]
      raise Stop, "Source root must be canonical" unless root.is_a?(String) && File.realpath(root) == root && File.directory?(root)
      root_stat = File.lstat(root)
      @root_identity = [root_stat.dev, root_stat.ino]
      files = @data["files"]
      raise Stop, "Missing immutable session artifacts" unless files.is_a?(Hash) && files.keys.sort == %w[source test_host xctestrun monitor].sort
      files.each_value do |entry|
        unless entry.is_a?(Hash) && entry.keys.sort == %w[path sha256] && entry["path"].is_a?(String) && entry["path"].start_with?(root + "/") &&
               entry["sha256"].is_a?(String) && entry["sha256"].match?(/\A[0-9a-f]{64}\z/)
          raise Stop, "Invalid artifact identity"
        end
      end
      verify_sizes!(deadline: deadline)
      @identities = files.to_h do |role, entry|
        identity, = self.class.read_identity(entry["path"], limit: FILE_LIMITS.fetch(role), deadline: deadline)
        raise Stop, "Artifact SHA256 mismatch" unless identity.last == entry["sha256"]
        [role, identity]
      end
      verify!(deadline: deadline)
    end

    def [](key)
      @data.fetch(key)
    end

    def verify_sizes!(deadline: NativeSimulatorSession.now + VALIDATION_SECONDS, progress: nil)
      total = File.lstat(@path).size
      self["files"].each do |role, entry|
        self.class.checkpoint!(deadline, progress)
        stat = File.lstat(entry.fetch("path"))
        raise Stop, "Identity must be a regular file" unless stat.file?
        raise Stop, "Artifact exceeds size limit" if stat.size > FILE_LIMITS.fetch(role)
        total += stat.size
      end
      raise Stop, "Session artifact budget exceeded" if total > TOTAL_BYTES
    end

    def verify!(deadline: NativeSimulatorSession.now + VALIDATION_SECONDS, progress: nil)
      identity, = self.class.read_identity(@path, limit: FILE_LIMITS.fetch("plan"), deadline: deadline, progress: progress)
      raise Stop, "Plan identity changed" unless identity == @plan_identity
      root = File.lstat(self["source_root"])
      raise Stop, "Source root identity changed" unless root.directory? && [root.dev, root.ino] == @root_identity && File.realpath(self["source_root"]) == self["source_root"]
      verify_sizes!(deadline: deadline, progress: progress)
      xml = nil
      @identities.each do |role, expected|
        observed, contents = self.class.read_identity(expected.first, limit: FILE_LIMITS.fetch(role), deadline: deadline,
          progress: progress, capture: role == "xctestrun")
        raise Stop, "Artifact identity changed" unless observed == expected
        xml = contents if role == "xctestrun"
      end
      xml_path = self["files"].fetch("xctestrun").fetch("path")
      raise Stop, "xctestrun entities are not accepted" if xml.match?(/<!ENTITY/i)
      # Parsing is bounded by the XML byte cap, but is not supervised per chunk.
      # A final checkpoint refuses the next operation if parsing exhausts time.
      keys = REXML::Document.new(xml).get_elements("//key")
      keys.select { |key| key.text == "TestBundlePath" }.each do |key|
        value = key.next_element
        unless value&.name == "string" && value.text.is_a?(String) && !value.text.empty? && !value.text.include?("\0")
          raise Stop, "Invalid TestBundlePath"
        end
        path = value.text
        if path.start_with?("__TESTROOT__/")
          path = File.expand_path(path.delete_prefix("__TESTROOT__/"), File.dirname(xml_path))
        end
        unless path.start_with?("/") && !path.match?(/__[^\/]*__/)
          raise Stop, "Unsupported TestBundlePath reference"
        end
        begin
          resolved = File.realpath(path)
          unless resolved.start_with?(self["source_root"] + "/") && File.directory?(resolved)
            raise Stop, "TestBundlePath must be a directory inside source root"
          end
        rescue SystemCallError
          raise Stop, "Invalid TestBundlePath directory"
        end
      end
      hosts = keys.filter_map do |key|
        next unless key.text == "TestHostPath"
        value = key.next_element
        raise Stop, "Invalid TestHostPath" unless value&.name == "string" && value.text.is_a?(String)
        value.text.gsub("__TESTROOT__", File.dirname(xml_path))
      end
      expected = self["files"].fetch("test_host").fetch("path")
      raise Stop, "xctestrun TestHost identity mismatch" unless !hosts.empty? && hosts.all? { |host| host == expected }
      self.class.checkpoint!(deadline, progress)
      true
    rescue REXML::ParseException => error
      raise Stop, "Invalid xctestrun: #{error.class}"
    end
  end

  class Report
    attr_reader :data
    def initialize(path)
      @path = File.expand_path(path)
      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      @data = { "decision" => "deny", "cleanup_verified" => false, "fatal_panic" => false,
                "owner_pid" => Process.pid, "process_groups" => [], "events" => [] }
      save
    end

    def save
      Tempfile.create([".session-report-", ".json"], File.dirname(@path)) do |file|
        file.chmod(0o600)
        file.write(JSON.generate(@data))
        file.flush
        file.fsync
        File.rename(file.path, @path)
      end
    end

    def event(phase, state)
      raise Stop, "Session event budget exceeded" if @data["events"].length >= 256
      @data["events"] << { "phase" => phase.to_s, "state" => state, "monotonic" => NativeSimulatorSession.now }
      save
    end
  end

  class Monitor
    attr_reader :denial

    LIMITS = { "minimum_free_percent" => 20, "minimum_disk_bytes" => 8 * 1024**3,
               "maximum_swap_growth_bytes" => 256 * 1024**2,
               "maximum_sample_seconds" => 5.0, "query_timeout_seconds" => 2.0 }.freeze
    def initialize(reader, log, duration)
      @reader, @log, @duration = reader, log, duration
      @buffer = +""
      @policy = false
      @sample = nil
      @baseline = nil
      @denial = nil
    end

    def pump
      16.times do
        bytes = @reader.read_nonblock(4096, exception: false)
        break if bytes == :wait_readable
        if bytes.nil?
          deny(Stop.new("Resource monitor ended unexpectedly"))
          break
        end
        @log.write(bytes)
        @log.flush
        @buffer << bytes
        raise Stop, "Resource monitor record exceeds limit" if @buffer.bytesize > 65_536
        while (line = @buffer.slice!(/\A[^\n]*\n/))
          record = JSON.parse(line)
          raise Stop, "Resource monitor record must be an object" unless record.is_a?(Hash)
          consume(record)
        end
      end
    rescue Stop => error
      deny(error)
    rescue JSON::ParserError, IOError, SystemCallError => error
      deny(Stop.new("Invalid resource monitor stream: #{error.class}"))
    end

    def deny(error)
      return if @denial&.fatal
      @denial = error if error.fatal || @denial.nil? || (@denial.is_a?(ResourceDenied) && !error.is_a?(ResourceDenied))
    end

    def consume(record)
      case record["event"]
      when "policy"
        unless !@policy && record["limits"] == LIMITS && record["load1_limit"] == "min(6.0, 0.75 * logical_cpus)" &&
               record["duration_seconds"] == @duration && record["interval_seconds"].is_a?(Numeric) && record["interval_seconds"].between?(0.1, 5)
          raise Stop, "Resource monitor policy mismatch"
        end
        @policy = true
      when "sample"
        raise Stop, "Resource sample preceded policy" unless @policy
        sample = record["sample"]
        raise Stop, "Invalid resource sample" unless sample.is_a?(Hash)
        %w[collected_monotonic started_monotonic collection_seconds memory_bytes logical_cpus memory_free_percent disk_free_bytes swap_used_bytes].each do |key|
          value = sample[key]
          raise Stop, "Invalid resource sample field: #{key}" unless value.is_a?(Numeric) && value.finite? && value >= 0
        end
        load = sample["load_averages"]
        panics = sample["panic_identities"]
        elapsed = sample["collected_monotonic"] - sample["started_monotonic"]
        # Allow only floating-point round-trip noise in the producer's subtraction.
        consistent_duration = (sample["collection_seconds"] - elapsed).abs <= 1e-6
        unless load.is_a?(Array) && load.length == 3 && load.all? { |value| value.is_a?(Numeric) && value.finite? && value >= 0 } &&
               panics.is_a?(Array) && panics.length <= 4096 && panics.all? { |value| value.is_a?(String) && value.bytesize <= 4096 } &&
               sample["logical_cpus"].positive? && sample["memory_bytes"].positive? && sample["memory_free_percent"] <= 100 &&
               elapsed.between?(0, 5) && consistent_duration && sample["collection_seconds"] <= 5 &&
               (!@sample || sample["collected_monotonic"] > @sample["collected_monotonic"])
          raise Stop, "Invalid or replayed resource sample"
        end
        @baseline ||= sample
        if (panics - @baseline["panic_identities"]).any?
          deny(Stop.new("New panic report detected", fatal: true))
        elsif record["decision"] != "allow" || record["reasons"] != [] ||
              sample["memory_free_percent"] < 20 || sample["disk_free_bytes"] < LIMITS["minimum_disk_bytes"] ||
              sample["swap_used_bytes"] - @baseline["swap_used_bytes"] > LIMITS["maximum_swap_growth_bytes"] ||
              load.first > [6.0, 0.75 * sample["logical_cpus"]].min
          deny(ResourceDenied.new("Resource monitor denied session"))
        end
        @sample = sample
      when "collection_error", "final"
        reasons = record["reasons"]
        fatal = record["fatal_stop"] == true || (reasons.is_a?(Array) && reasons.any? { |reason| reason.is_a?(String) && reason.start_with?("new or changed panic report detected") })
        deny(Stop.new(fatal ? "New panic report detected" : "Resource monitor stopped or failed", fatal: fatal))
      else
        raise Stop, "Unknown resource monitor record"
      end
    end

    def check!(cleanup: false)
      pump
      raise @denial if @denial && (!cleanup || !@denial.is_a?(ResourceDenied))
      return false unless @sample
      age = NativeSimulatorSession.now - @sample["collected_monotonic"]
      raise Stop, "Resource monitor sample is stale" unless age.between?(0, 5)
      true
    end
  end

  def self.stop_group(group, limit: 0.15)
    Process.kill("TERM", -group) rescue Errno::ESRCH
    until now >= (deadline ||= now + limit)
      begin
        Process.kill(0, -group)
      rescue Errno::ESRCH
        return
      end
      sleep 0.01
    end
    Process.kill("KILL", -group) rescue Errno::ESRCH
  end

  class Caretaker
    def initialize(plan, backend, lease, lock_path, groups, owner, report, started)
      @plan, @backend, @lease, @lock_path = plan, backend, lease, lock_path
      @groups, @owner, @report, @started = groups, owner, report, started
      @deadline = started + plan["duration_seconds"]
      @work_deadline = @deadline - plan["cleanup_timeout_seconds"]
      @work_started = false
      @counter = 0
      @children = []
      @logs = Dir.mktmpdir(".session-logs-", File.dirname(lock_path))
    end

    def spawn_operation(phase, group, out:, err:, deadline:, cleanup: false)
      progress = -> { check!(deadline, cleanup: cleanup) }
      @plan.verify!(deadline: deadline, progress: progress)
      argv = @backend.argv(phase, @plan)
      environment = @backend.environment(phase, @plan)
      unless argv.is_a?(Array) && argv.length.between?(1, 64) && argv.all? { |value| value.is_a?(String) && !value.empty? && !value.include?("\0") } &&
             environment.is_a?(Hash) && environment.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
        raise Stop, "Invalid injected operation contract"
      end
      env = { "PATH" => ENV.fetch("PATH"), "LC_ALL" => "C" }.merge(environment).merge(
        NativeJob::FD_ENV => NativeJob::CHILD_FD.to_s, NativeJob::PATH_ENV => @lock_path)
      check!(deadline, cleanup: cleanup)
      pid = Process.spawn(env, [argv.first, argv.first], *argv.drop(1), { pgroup: group, out: out, err: err, close_others: true, unsetenv_others: true, NativeJob::CHILD_FD => @lease })
      @children << pid
      @work_started = true if phase == :boot
      pid
    end

    def check!(deadline, cleanup: false)
      raise Stop, "Session deadline exceeded" if NativeSimulatorSession.now >= deadline
      unless cleanup
        message = @owner.read_nonblock(1024, exception: false)
        raise Stop, "Session owner disappeared or cancelled" unless message == :wait_readable
      end
      @monitor&.check!(cleanup: cleanup)
    end

    def operation(phase, cleanup: false)
      deadline = [@deadline, NativeSimulatorSession.now + @plan["phase_timeout_seconds"]].min
      deadline = [deadline, @work_deadline].min unless cleanup
      check!(deadline, cleanup: cleanup)
      @plan.verify!(deadline: deadline, progress: -> { check!(deadline, cleanup: cleanup) })
      @report.event(phase, "started")
      @counter += 1
      path = File.join(@logs, "#{@counter}-#{phase}.log")
      pid = File.open(path, "wx", 0o600) do |log|
        spawn_operation(phase, @groups[cleanup ? 1 : 0], out: log, err: log, deadline: deadline, cleanup: cleanup)
      end
      status = nil
      until status
        check!(deadline, cleanup: cleanup)
        result = Process.waitpid2(pid, Process::WNOHANG)
        status = result&.last
        sleep 0.01 unless status
      end
      @children.delete(pid)
      raise Stop, "#{phase} failed with status #{status.exitstatus || status.termsig}" unless status.success?
      @report.event(phase, "finished")
      (File.binread(path, 65_537) || "").tap { |output| raise Stop, "Operation output exceeds limit" if output.bytesize > 65_536 }
    end

    def inspect_target!(cleanup: false, initial: false)
      state = JSON.parse(operation(:inspect, cleanup: cleanup))
      target = state["device"]
      expected = @plan["device"]
      unless target.is_a?(Hash) && expected.all? { |key, value| target[key] == value } &&
             %w[Shutdown Booted].include?(target["state"]) && state["xcode_version"] == "16.4" &&
             (!initial || target["state"] == "Shutdown")
        raise Stop, "Observed target identity or initial state mismatch"
      end
    rescue JSON::ParserError
      raise Stop, "Invalid target inspection"
    end

    def execute
      code = 75
      begin
        reader, writer = IO.pipe
        error_log = File.open(File.join(@logs, "monitor-errors.log"), "wx", 0o600)
        startup = [@work_deadline, NativeSimulatorSession.now + @plan["phase_timeout_seconds"]].min
        @monitor_pid = spawn_operation(:monitor, @groups[1], out: writer, err: error_log, deadline: startup)
        writer.close
        error_log.close
        @monitor_log = File.open(File.join(@logs, "resources.jsonl"), "wx", 0o600)
        @monitor = Monitor.new(reader, @monitor_log, @plan["duration_seconds"])
        until @monitor.check!
          check!(startup)
          sleep 0.01
        end
        inspect_target!(initial: true)
        %i[boot install test].each do |phase|
          inspect_target!(initial: phase == :boot)
          operation(phase)
        end
        code = 0
      rescue StandardError => error
        @report.data["reason"] = error.message
        @report.data["fatal_panic"] = error.is_a?(Stop) && error.fatal
      ensure
        NativeSimulatorSession.stop_group(@groups[0])
        if @work_started && !@report.data["fatal_panic"]
          begin
            %i[terminate shutdown quit verify].each do |phase|
              inspect_target!(cleanup: true)
              output = operation(phase, cleanup: true)
              if phase == :verify
                verified = JSON.parse(output)
                unless %w[shutdown simulator_app_absent simmetalhost_absent].all? { |key| verified[key] == true }
                  raise Stop, "Cleanup could not confirm shutdown and renderer exit"
                end
              end
            end
            @report.data["cleanup_verified"] = true
          rescue StandardError => error
            code = 75
            @report.data["cleanup_error"] = error.message
            @report.data["fatal_panic"] ||= error.is_a?(Stop) && error.fatal
          end
        end
        if (denial = @monitor&.denial)
          code = 75
          @report.data["reason"] ||= denial.message
          @report.data["fatal_panic"] ||= denial.fatal
        end
        NativeSimulatorSession.stop_group(@groups[1])
        @children.each { |pid| Process.waitpid(pid) rescue Errno::ECHILD }
        @monitor_log&.close
        reader&.close
        writer&.close unless writer&.closed?
        error_log&.close unless error_log&.closed?
        code = 75 unless @report.data["cleanup_verified"]
        @report.data["decision"] = code.zero? ? "allow" : "deny"
        @report.data["logs_directory"] = @logs
        @report.data["elapsed_seconds"] = NativeSimulatorSession.now - @started
        @report.save
      end
      code
    end
  end

  def self.run(plan_path:, backend:, lock_path:, report_path:)
    # Importing the module must not provide an alternate route on the real Mac.
    return 75 if RUBY_PLATFORM.include?("darwin") || !Process.respond_to?(:fork)

    lease = nil
    inherited = false
    leaders = []
    controls = []
    caretaker = nil
    owner_writer = nil
    report = nil
    previous = {}
    parent_signal = nil
    started = now
    begin
      lease, inherited = NativeJob.lease(File.expand_path(lock_path))
      report = Report.new(report_path)
      plan = Plan.new(plan_path)
      %w[INT TERM HUP].each { |name| previous[name] = Signal.trap(name) { parent_signal ||= name } }
      2.times do
        reader, writer = IO.pipe
        pid = Process.spawn(RbConfig.ruby, "-e", "IO.for_fd(8).read", {
          pgroup: true, close_others: true, 8 => reader, NativeJob::CHILD_FD => lease,
          out: File::NULL, err: File::NULL
        })
        reader.close
        leaders << pid
        controls << writer
      end
      report.data["process_groups"] = leaders.dup
      report.save
      owner_reader, owner_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      caretaker = fork do
        owner_writer.close
        gate_writer.close
        %w[INT TERM HUP].each { |name| Signal.trap(name) { owner_reader.close rescue IOError } }
        report.data["caretaker_pid"] = Process.pid
        if gate_reader.read(1) == "1"
          gate_reader.close
          code = Caretaker.new(plan, backend, lease, File.expand_path(lock_path), leaders, owner_reader, report, started).execute
          exit! code
        end
        leaders.each { |pid| stop_group(pid) }
        exit! 75
      end
      owner_reader.close
      gate_reader.close
      controls.each(&:close)
      report.data["caretaker_pid"] = caretaker
      report.save
      gate_writer.write("1")
      gate_writer.close
      status = nil
      until status
        if parent_signal && !owner_writer.closed?
          owner_writer.write("cancel #{parent_signal}\n") rescue Errno::EPIPE
          owner_writer.close
        end
        result = Process.waitpid2(caretaker, Process::WNOHANG)
        status = result&.last
        if now > started + plan["duration_seconds"] + 0.5 && !status
          Process.kill("KILL", caretaker) rescue Errno::ESRCH
          _, status = Process.waitpid2(caretaker)
        end
        sleep 0.01 unless status
      end
      caretaker = nil # Reaped PIDs must never become a later termination target.
      leaders.each { |pid| stop_group(pid) }
      leaders.each { |pid| Process.waitpid(pid) rescue Errno::ECHILD }
      leaders.clear
      final = JSON.parse(File.read(report_path))
      unless status.success? && final["decision"] == "allow" && final["cleanup_verified"] == true
        # A dead caretaker may have seen a panic before reporting it. Do not
        # start fresh cleanup commands from this fallback; preserve incomplete.
        unless status.exited? && status.exitstatus == 75 && final["decision"] == "deny"
          report.data.replace(final.merge("decision" => "deny", "cleanup_verified" => false,
                                          "reason" => "Caretaker lost; cleanup incomplete"))
          report.save
        end
        return parent_signal ? 128 + Signal.list.fetch(parent_signal) : 75
      end
      parent_signal ? 128 + Signal.list.fetch(parent_signal) : 0
    rescue StandardError => error
      if report
        report.data["reason"] = error.message
        report.data["decision"] = "deny"
        report.save
      end
      75
    ensure
      owner_writer&.close unless owner_writer&.closed?
      if caretaker
        begin
          Process.kill("KILL", caretaker)
          Process.waitpid(caretaker)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
      leaders.each { |pid| stop_group(pid); Process.waitpid(pid) rescue Errno::ECHILD }
      controls.each { |writer| writer.close unless writer.closed? }
      previous.each { |name, handler| Signal.trap(name, handler) }
      lease&.close unless inherited
    end
  end

  def self.main(_arguments)
    warn "Simulator sessions remain quarantined pending supervised execution review."
    75
  end
end

exit NativeSimulatorSession.main(ARGV) if $PROGRAM_NAME == __FILE__
