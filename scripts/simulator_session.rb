# frozen_string_literal: true

require "time"
require_relative "simulator_resources"
require_relative "native_job"

# The detached watchdog owns the lease, telemetry, subprocesses and cleanup.
# The foreground process supplies heartbeats; its death is never a success.
module SimulatorSession
  class Supervisor
    def initialize(backend:, sampler:, report:, heartbeat:, lease_path: NativeJob::LOCK_PATH,
                   baseline_seconds: 60, interval: 5, session_seconds: 600, boot_seconds: 120,
                   journey_seconds: 15, stable_existing_swap: false, observe_resources: false,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @backend, @sampler, @report, @heartbeat = backend, sampler, report, heartbeat
      @lease_path, @baseline_seconds, @interval = lease_path, baseline_seconds, interval
      @session_seconds, @boot_seconds, @journey_seconds, @clock = session_seconds, boot_seconds, journey_seconds, clock
      @evidence = { "started_at" => Time.now.utc.iso8601, "samples" => [], "events" => [] }
      @stable_existing_swap = stable_existing_swap
      @observe_resources = observe_resources
      @evidence["admission_policy"] = stable_existing_swap ? "explicit_stable_existing_swap" : "strict_1gib_swap"
      @evidence["admission_policy"] = "explicit_resource_observation" if observe_resources
      @evidence["limits"] = { "baseline_seconds" => baseline_seconds, "session_seconds" => session_seconds,
                              "boot_seconds" => boot_seconds, "app_seconds" => journey_seconds }
      @last_heartbeat = @clock.call
    end

    def record(event)
      @phase = event
      @evidence["events"] << { "event" => event, "at" => Time.now.utc.iso8601 }
      persist
    end

    def persist
      temporary = @report + ".tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(@evidence)) }
      File.rename(temporary, @report)
    end

    def check_heartbeat
      loop do
        chunk = @heartbeat.read_nonblock(4096)
        raise SimulatorResources::Refusal, "Foreground cancelled session" if chunk.include?("!")
        @last_heartbeat = @clock.call
      end
    rescue IO::WaitReadable
      raise SimulatorResources::Refusal, "Foreground heartbeat lost" if @clock.call - @last_heartbeat > 15
    rescue EOFError
      raise SimulatorResources::Refusal, "Foreground exited"
    end

    def sample
      check_heartbeat
      @backend.check_app if @backend.respond_to?(:check_app)
      snapshot = @sampler.call
      check_heartbeat
      @last_snapshot = snapshot
      SimulatorResources.validate(snapshot)
      @evidence["samples"] << snapshot.merge("elapsed_seconds" => @clock.call - @started, "phase" => @phase)
      persist
      snapshot
    end

    def baseline
      deadline = @clock.call + @baseline_seconds
      initial = nil
      loop do
        sampled_at = @clock.call
        snapshot = sample
        initial ||= snapshot
        refusal = admission(snapshot, initial)
        raise SimulatorResources::Refusal, refusal if refusal
        return snapshot if @clock.call >= deadline
        sleep [@interval - (@clock.call - sampled_at), 0].max
      end
    end

    def admission(snapshot, initial)
      if @observe_resources
        SimulatorResources.validate(snapshot)
        return "Memory pressure is not normal" unless snapshot["pressure"] == 1
        return "Free disk below 20 GiB" if snapshot["free_bytes"] < 20 * 1024**3
        return nil
      end
      refusal = SimulatorResources.admission(snapshot, initial, stable_existing_swap: @stable_existing_swap,
                                             previous: @admission_previous || initial)
      @admission_previous = snapshot
      refusal
    end

    def watch
      @backend.check_ui if @backend.respond_to?(:check_ui)
      check_heartbeat
      now = @clock.call
      raise SimulatorResources::Refusal, "Session deadline exceeded" if now >= @deadline
      return if now < @next_sample
      refusal = @monitor.check(sample, @clock.call)
      raise SimulatorResources::Refusal, refusal if refusal
      raise SimulatorResources::Refusal, "Session deadline exceeded" if @clock.call >= @deadline
      @next_sample = now + @interval
    end

    def command(stage, timeout:)
      @backend.prepare(stage) if @backend.respond_to?(:prepare)
      watch
      if stage == :boot
        refusal = admission(@last_snapshot, @admission_initial)
        raise SimulatorResources::Refusal, refusal if refusal
      end
      check_heartbeat
      record(stage.to_s)
      @cleanup_needed = true if stage == :boot
      @backend.start(stage)
      deadline = [@clock.call + timeout, @deadline].min
      loop do
        watch
        raise SimulatorResources::Refusal, "#{stage} deadline exceeded" if @clock.call >= deadline
        status = @backend.poll
        if status
          raise SimulatorResources::Refusal, "#{stage} failed (#{status})" unless status == 0
          return
        end
        raise SimulatorResources::Refusal, "#{stage} deadline exceeded" if @clock.call >= deadline
        sleep 0.1
      end
    end

    def run
      raise SimulatorResources::Refusal, "Report exists" if File.exist?(@report) || File.exist?(@report + ".tmp")
      @can_persist = true
      @lease, inherited = NativeJob.lease(@lease_path)
      raise SimulatorResources::Refusal, "Session must own a standalone lease" if inherited
      @started = @clock.call
      @evidence["identity"] = @backend.inspect_identity
      @backend.recheck
      record("baseline")
      initial = baseline
      @backend.recheck_idle
      refusal = admission(sample, initial)
      raise SimulatorResources::Refusal, refusal if refusal
      @admission_initial = initial
      @monitor = SimulatorResources::Monitor.new(initial, observation_only: @observe_resources)
      @deadline = @clock.call + @session_seconds
      @next_sample = @clock.call
      command(:boot, timeout: @boot_seconds)
      command(:ready, timeout: [@boot_seconds - (@clock.call - (@deadline - @session_seconds)), 0].max)
      command(:ui, timeout: 10)
      command(:install, timeout: 60)
      command(:launch, timeout: 30)
      @evidence['app_pid'] = @backend.app_pid if @backend.respond_to?(:app_pid)
      record('app_observation')
      ending = @clock.call + @journey_seconds
      while @clock.call < ending
        watch
        sleep 0.1
      end
      @backend.check_app if @backend.respond_to?(:check_app)
      if @backend.respond_to?(:test_session?) && @backend.test_session?
        command(:test, timeout: 120)
        @evidence["result"] = "test_command_completed"
      else
        @evidence["result"] = "launch_smoke_passed"
      end
    rescue StandardError => error
      @evidence["result"] = "blocked_or_failed"
      @evidence["error"] = "#{error.class}: #{error.message}"
    ensure
      if @cleanup_needed
        begin
          @evidence["cleanup"] = @backend.cleanup
          raise SimulatorResources::Refusal, "Cleanup not verified" unless @evidence["cleanup"] == "verified_shutdown"
        rescue StandardError => error
          @evidence["cleanup"] = "failed: #{error.message}"
          @evidence["result"] = "cleanup_failed"
        end
      end
      begin
        @evidence["final_resources"] = @sampler.call if @started
      rescue StandardError => error
        @evidence["final_resource_error"] = error.message
        @evidence["result"] = "final_telemetry_failed" if %w[launch_smoke_passed test_command_completed].include?(@evidence["result"])
      end
      @evidence["finished_at"] = Time.now.utc.iso8601
      begin
        persist if @can_persist
      ensure
        @lease&.close unless inherited
      end
    end

    def successful?
      %w[launch_smoke_passed test_command_completed].include?(@evidence["result"]) && @evidence["cleanup"] == "verified_shutdown"
    end
  end

  def self.launch(backend:, sampler:, report:, **timing)
    reader, writer = IO.pipe
    pid = fork do
      writer.close
      Process.setsid
      supervisor = Supervisor.new(backend: backend, sampler: sampler, report: report, heartbeat: reader, **timing)
      supervisor.run
      exit! supervisor.successful? ? 0 : 75
    end
    reader.close
    signal = false
    previous = %w[INT TERM HUP].to_h { |name| [name, Signal.trap(name) { signal = true }] }
    loop do
      writer.write(signal ? "!" : ".")
      result = Process.waitpid2(pid, Process::WNOHANG)
      return result.last.exitstatus || 75 if result
      sleep 1
    rescue Errno::EPIPE
      return Process.waitpid2(pid).last.exitstatus || 75
    end
  ensure
    writer&.close
    reader&.close unless reader&.closed?
    previous&.each { |name, handler| Signal.trap(name, handler) }
  end
end
