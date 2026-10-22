# frozen_string_literal: true

# Loaded by test_native_simulator_session.rb; preserve the existing suite selectors and fixture.
class NativeSimulatorSessionTest
  def assert_hash_progress_stop(mode)
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    source = @plan.fetch("files").fetch("source").fetch("path")
    File.write(source, "a" * (2 * NativeSimulatorSession::Plan::CHUNK_BYTES))
    @plan["files"]["source"]["sha256"] = Digest::SHA256.file(source).hexdigest
    @plan["phase_timeout_seconds"] = 10.0
    @plan["duration_seconds"] = 30.0
    File.write(@plan_path, JSON.generate(@plan))
    clock = NativeSimulatorSession.now
    policy = { "event" => "policy", "limits" => NativeSimulatorSession::Monitor::LIMITS,
               "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
               "duration_seconds" => 30.0, "interval_seconds" => 0.1 }
    sample = { "started_monotonic" => clock, "collected_monotonic" => clock,
               "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
               "logical_cpus" => 8, "memory_free_percent" => 58,
               "disk_free_bytes" => 12 * 1024**3, "swap_used_bytes" => 0,
               "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => [] }
    record = ->(value) { JSON.generate("event" => "sample", "decision" => "allow", "reasons" => [], "sample" => value) + "\n" }
    monitor_reader, monitor_writer = IO.pipe
    ack_reader, ack_writer = IO.pipe
    resume_reader, resume_writer = IO.pipe
    owner_reader, owner_writer = IO.pipe
    result_path = File.join(@directory, "hash-result.json")
    monitor_writer.write(JSON.generate(policy) + "\n" + record.call(sample))
    monitor_writer.flush
    child = fork do
      [monitor_writer, ack_reader, resume_writer, owner_writer].each(&:close)
      result = {}
      begin
        plan = NativeSimulatorSession::Plan.new(@plan_path)
        lease, = NativeJob.lease(@lease)
        caretaker = NativeSimulatorSession::Caretaker.new(plan, FakeBackend.new(@directory), lease,
          @lease, [true, true], owner_reader, NativeSimulatorSession::Report.new(@report), clock)
        caretaker.instance_variable_set(:@monitor, NativeSimulatorSession::Monitor.new(monitor_reader, StringIO.new, 30.0))
        original_open = File.method(:open)
        opened = nil
        paused = false
        intercept = lambda do |name, *arguments, &block|
          unless name == source
            next original_open.call(name, *arguments, &block)
          end
          original_open.call(name, *arguments) do |file|
            opened = file
            original_read = file.method(:read)
            file.define_singleton_method(:read) do |length|
              chunk = original_read.call(length)
              unless paused
                paused = true
                ack_writer.write("read\n")
                ack_writer.flush
                raise "Missing hash acknowledgement" unless resume_reader.read(1) == "1"
                # A controlled clock crossing exercises expiry without a timing race.
                clock += mode == "stale" ? 6 : mode == "deadline" ? 11 : 0.001
              end
              chunk
            end
            block.call(file)
          end
        end
        with_method(NativeSimulatorSession, :now, -> { clock }) do
          with_method(File, :open, intercept) do
            begin
              caretaker.operation(:inspect)
              result["reason"] = "Unexpected operation success"
            rescue NativeSimulatorSession::Stop => error
              result["reason"] = error.message
              result["fatal"] = error.fatal
              result["closed"] = opened&.closed?
              if mode == "panic"
                result["fatal_refusals"] = %i[inspect shutdown].count do |phase|
                  begin
                    caretaker.operation(phase, cleanup: true)
                    false
                  rescue NativeSimulatorSession::Stop => repeated
                    repeated.fatal
                  end
                end
              end
            end
          end
        end
      rescue StandardError => error
        result["fixture_error"] = "#{error.class}: #{error.message}"
      ensure
        lease&.close
        File.write(result_path, JSON.generate(result))
      end
      exit! 0
    end
    [monitor_reader, ack_writer, resume_reader, owner_reader].each(&:close)
    assert_equal "read\n", Timeout.timeout(12) { ack_reader.gets }, failure_diagnostics
    if mode == "panic"
      monitor_writer.write(record.call(sample.merge("started_monotonic" => clock + 0.001,
        "collected_monotonic" => clock + 0.001, "panic_identities" => ["owned new panic"])))
      monitor_writer.flush
    elsif mode == "cancel"
      owner_writer.close
    end
    resume_writer.write("1")
    resume_writer.close
    _, status = Timeout.timeout(12) { Process.waitpid2(child) }
    child = nil
    assert status.success?
    result = JSON.parse(File.read(result_path))
    refute result.key?("fixture_error"), result.inspect
    assert_equal true, result["closed"], result.inspect
    assert_empty operations, "Hash refusal must precede every new backend operation"
    case mode
    when "panic"
      assert_equal true, result["fatal"]
      assert_equal 2, result["fatal_refusals"]
    when "cancel" then assert_match(/owner disappeared or cancelled/, result.fetch("reason"))
    when "stale" then assert_match(/sample is stale/, result.fetch("reason"))
    when "deadline" then assert_match(/deadline/, result.fetch("reason"))
    end
  ensure
    if child
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.waitpid(child) rescue Errno::ECHILD
    end
    [monitor_reader, monitor_writer, ack_reader, ack_writer, resume_reader, resume_writer,
     owner_reader, owner_writer].compact.each { |io| io.close unless io.closed? }
  end

  def test_hashing_pumps_new_panic_and_never_starts_inspect_or_cleanup
    assert_hash_progress_stop("panic")
  end

  def test_hashing_rechecks_monitor_freshness_between_chunks
    assert_hash_progress_stop("stale")
  end

  def test_hashing_observes_owner_cancellation_before_starting_an_operation
    assert_hash_progress_stop("cancel")
  end

  def test_hashing_observes_phase_deadline_before_starting_an_operation
    assert_hash_progress_stop("deadline")
  end
end
