# frozen_string_literal: true

module NativeSimulatorSession
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
end
