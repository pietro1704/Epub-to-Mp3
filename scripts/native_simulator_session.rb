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

  require_relative "native_session/artifact_plan"

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

  require_relative "native_session/resource_monitor"

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

  require_relative "native_session/session_caretaker"

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
