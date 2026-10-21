# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "timeout"
require "stringio"
require "shellwords"

# The process contract runs only fake Ruby tools. No Apple service is queried.
class NativeSimulatorSessionTest < Minitest::Test
  SCRIPT = File.expand_path("native_simulator_session.rb", __dir__)
  RUBY = RbConfig.ruby
  UUID = "018637F5-CC86-449C-B071-D7D0C43FBEE0"

  class FakeBackend
    def initialize(directory, mode: "success")
      @directory = directory
      @mode = mode
    end

    def argv(phase, _plan)
      [RbConfig.ruby, File.join(@directory, "fake_tool.rb"), phase.to_s]
    end

    def environment(_phase, _plan)
      { "SESSION_FIXTURE" => @directory, "SESSION_MODE" => @mode }
    end
  end

  def setup
    @directory = File.realpath(Dir.mktmpdir("simulator-session-contract-"))
    @lease = File.join(@directory, "heavy.lease")
    @report = File.join(@directory, "session.json")
    @plan_path = File.join(@directory, "plan.json")
    @marker = File.join(@directory, "operations.jsonl")
    host = File.join(@directory, "EpubToMp3.app", "EpubToMp3")
    FileUtils.mkdir_p(File.dirname(host))
    File.write(host, "owned test application executable")
    source = File.join(@directory, "source.swift")
    File.write(source, "source identity fixture")
    @tool = File.join(@directory, "fake_tool.rb")
    File.write(@tool, <<~'RUBY')
      require "json"
      require "fileutils"
      directory = ENV.fetch("SESSION_FIXTURE")
      phase = ARGV.fetch(0)
      mode = ENV.fetch("SESSION_MODE")
      require "socket" if mode == "cleanup_resource_deny"
      if phase == "monitor"
        puts JSON.generate("event" => "policy", "limits" => {
          "minimum_free_percent" => 20, "minimum_disk_bytes" => 8 * 1024**3,
          "maximum_swap_growth_bytes" => 256 * 1024**2,
          "maximum_sample_seconds" => 5.0, "query_timeout_seconds" => 2.0
        }, "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
           "duration_seconds" => 15.0, "interval_seconds" => 0.1)
        STDOUT.sync = true
        exit 0 if mode == "monitor_eof"
        acknowledged = false
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          sample_started = mode == "old_collection_start" ? now - [100.0, now / 2].min : now
          denied = mode == "initial_resource_deny" ||
            (mode == "cleanup_resource_deny" && File.exist?(File.join(directory, "deny-requested")))
          panics = File.exist?(File.join(directory, "new-panic")) ? ["new-owned-panic-report"] : []
          puts JSON.generate("event" => "sample", "decision" => denied ? "deny" : "allow",
            "reasons" => denied ? ["available disk space below minimum"] : [],
            "sample" => { "started_monotonic" => sample_started, "collected_monotonic" => now,
              "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
              "logical_cpus" => 8, "memory_free_percent" => 58,
              "disk_free_bytes" => (denied ? 4 : 12) * 1024**3, "swap_used_bytes" => 0,
              "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => panics })
          STDOUT.flush
          if mode == "cleanup_resource_deny" && denied && !acknowledged
            UNIXSocket.open(File.join(directory, "deny.socket")) { |socket| socket.write("sample flushed") }
            acknowledged = true
          end
          sleep 0.03
        end
      end
      File.open(File.join(directory, "operations.jsonl"), "a") do |file|
        file.puts(JSON.generate("phase" => phase, "pid" => Process.pid,
                               "pgid" => Process.getpgrp))
      end
      case phase
      when "inspect"
        puts JSON.generate("device" => {
          "uuid" => "018637F5-CC86-449C-B071-D7D0C43FBEE0", "name" => "iPhone SE",
          "device_type" => "com.apple.CoreSimulator.SimDeviceType.iPhone-SE",
          "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-15-5", "state" => "Shutdown"
        }, "xcode_version" => "16.4")
      when "boot"
        File.write(File.join(directory, "booted"), "yes")
        exit 19 if mode == "boot_failure_after_start"
      when "install"
        if mode == "replace_artifact"
          source = File.join(directory, "source.swift")
          File.write(source + ".replacement", File.read(source))
          File.rename(source + ".replacement", source)
        end
      when "test"
        if %w[hold_test panic_during_test].include?(mode)
          descendant = fork { sleep 60 }
          File.write(File.join(directory, "worker-ready.json"), JSON.generate(
            "pid" => Process.pid, "descendant" => descendant, "pgid" => Process.getpgrp))
          File.write(File.join(directory, "new-panic"), "owned panic fixture") if mode == "panic_during_test"
          sleep 60
        else
          sleep 0.06
        end
      when "terminate"
        if mode == "cleanup_resource_deny"
          # The first denial is emitted only after cleanup starts, with an
          # acknowledgement rather than a race against the monitor interval.
          server = UNIXServer.new(File.join(directory, "deny.socket"))
          File.write(File.join(directory, "deny-requested"), "cleanup started")
          client = server.accept
          abort "missing resource denial acknowledgement" unless client.read == "sample flushed"
          client.close
          server.close
        end
      when "shutdown"
        exit 19 if mode == "cleanup_failure"
        if mode == "cleanup_timeout"
          descendant = fork { sleep 60 }
          File.write(File.join(directory, "cleanup-worker.json"), JSON.generate(
            "pid" => Process.pid, "descendant" => descendant, "pgid" => Process.getpgrp))
          sleep 60
        end
        # Cleanup still owns the same lease while the target is shutting down.
        File.open(File.join(directory, "heavy.lease"), "a+") do |lease|
          abort "lease was released before cleanup" if lease.flock(File::LOCK_EX | File::LOCK_NB)
        end
        FileUtils.rm_f(File.join(directory, "booted"))
      when "verify"
        exit 19 if File.exist?(File.join(directory, "booted"))
        puts JSON.generate("shutdown" => true, "simulator_app_absent" => true,
                           "simmetalhost_absent" => true)
      end
    RUBY
    xctestrun = File.join(@directory, "tests.xctestrun")
    File.write(xctestrun, <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>UnitTests</key><dict>
      <key>TestHostPath</key><string>#{host}</string>
      </dict></dict></plist>
    XML
    @plan = {
      "schema_version" => 1,
      "device" => { "uuid" => UUID, "name" => "iPhone SE",
                    "device_type" => "com.apple.CoreSimulator.SimDeviceType.iPhone-SE",
                    "runtime" => "com.apple.CoreSimulator.SimRuntime.iOS-15-5" },
      "xcode_path" => "/Applications/Xcode-16.4.0.app/Contents/Developer",
      "xcode_version" => "16.4", "source_revision" => "a" * 40,
      "source_root" => @directory,
      "files" => { "source" => source, "test_host" => host,
                   "xctestrun" => xctestrun, "monitor" => @tool }.transform_values do |path|
        { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest }
      end,
      "tests" => ["EpubToMp3Tests/BundledConverterFFISmokeTests/testAppBundledRustLibraryLoadsAndReturnsCatalog"],
      "duration_seconds" => 15.0, "phase_timeout_seconds" => 2.0,
      "cleanup_timeout_seconds" => 6.0
    }
    File.write(@plan_path, JSON.generate(@plan))
  end

  def teardown
    if passed?
      FileUtils.remove_entry(@directory)
    else
      warn "Retained fake session evidence: #{@directory}"
    end
  end

  def load_subject
    require_relative "native_simulator_session"
  end

  def run_session(mode: "success", backend: nil)
    load_subject
    NativeSimulatorSession.run(plan_path: @plan_path,
                              backend: backend || FakeBackend.new(@directory, mode: mode),
                              lock_path: @lease, report_path: @report)
  end

  def operations
    File.exist?(@marker) ? File.readlines(@marker).map { |line| JSON.parse(line) } : []
  end

  def plan_with_test_bundle_xml(value)
    load_subject
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key>#{value}</dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))
    NativeSimulatorSession::Plan.new(@plan_path)
  end

  def wait_for_fixture
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
    loop do
      result = yield
      return result if result
      flunk "Timed out waiting for owned fake fixture\n#{failure_diagnostics}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def read_fixture_json(path)
    JSON.parse(File.read(path)) if File.file?(path)
  rescue JSON::ParserError
    nil
  end

  def live_process?(pid)
    # A killed grandchild may briefly await init's reaper; it cannot hold FDs.
    stat = File.read("/proc/#{pid}/stat")
    stat.sub(/\A.*\) /, "").split.first != "Z"
  rescue Errno::ENOENT
    false
  end

  def with_held_session
    load_subject
    result_path = File.join(@directory, "owner-result.json")
    owner = fork do
      result = run_session(mode: "hold_test")
      File.write(result_path, JSON.generate("result" => result))
      exit! 0
    end
    worker = wait_for_fixture { read_fixture_json(File.join(@directory, "worker-ready.json")) }
    report = read_fixture_json(@report)
    assert_equal report.fetch("process_groups").first, worker.fetch("pgid")
    yield owner, report.fetch("caretaker_pid"), worker, result_path
  ensure
    if owner
      begin
        if Process.waitpid(owner, Process::WNOHANG).nil?
          Process.kill("TERM", owner)
          wait_for_fixture { Process.waitpid(owner, Process::WNOHANG) }
        end
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def assert_workers_stopped_and_lease_released(worker)
    wait_for_fixture { !live_process?(worker.fetch("pid")) && !live_process?(worker.fetch("descendant")) }
    available = wait_for_fixture do
      File.open(@lease, "a+") { |lease| lease.flock(File::LOCK_EX | File::LOCK_NB) }
    end
    assert available
  end

  def with_monitor_fixture(policy_changes: {}, sample_changes: {})
    load_subject
    reader, writer = IO.pipe
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    policy = { "event" => "policy", "limits" => NativeSimulatorSession::Monitor::LIMITS,
               "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
               "duration_seconds" => 15.0, "interval_seconds" => 0.1 }.merge(policy_changes)
    sample = { "started_monotonic" => now, "collected_monotonic" => now,
               "collection_seconds" => 0.0, "memory_bytes" => 8 * 1024**3,
               "logical_cpus" => 8, "memory_free_percent" => 58,
               "disk_free_bytes" => 12 * 1024**3, "swap_used_bytes" => 0,
               "load_averages" => [1.0, 1.0, 1.0], "panic_identities" => [] }.merge(sample_changes)
    writer.write(JSON.generate(policy) + "\n" + JSON.generate(
      "event" => "sample", "decision" => "allow", "reasons" => [], "sample" => sample) + "\n")
    writer.flush
    yield NativeSimulatorSession::Monitor.new(reader, StringIO.new, 15.0)
  ensure
    reader&.close
    writer&.close
  end

  def failure_diagnostics
    # These files contain only the owned fake process fixture, never host queries.
    paths = [@report, @marker] + Dir.glob(File.join(@directory, ".session-logs-*", "*"))
    paths.first(16).filter_map do |path|
      next unless File.file?(path) && !File.symlink?(path)
      next unless File.realpath(path).start_with?(File.realpath(@directory) + File::SEPARATOR)

      tail = File.open(path, "rb") do |file|
        file.seek([file.size - 2048, 0].max)
        file.read(2048) || +""
      end
      "#{path}:\n#{tail.force_encoding(Encoding::UTF_8).scrub}"
    end.join("\n")
  end

  # Scoped Ruby method replacement; Minitest 6 no longer includes minitest/mock.
  def with_method(receiver, name, replacement)
    own_method = receiver.singleton_class.instance_methods(false).include?(name)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &replacement)
    yield
  ensure
    if own_method
      receiver.define_singleton_method(name, original)
    else
      receiver.singleton_class.remove_method(name)
    end
  end

  def test_source_over_one_mib_is_rejected_even_with_a_valid_digest
    load_subject
    source = @plan.fetch("files").fetch("source")
    File.open(source.fetch("path"), "wb") { |file| file.truncate(1_048_577) }
    source["sha256"] = Digest::SHA256.file(source.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))

    error = assert_raises(NativeSimulatorSession::Stop) do
      NativeSimulatorSession::Plan.new(@plan_path)
    end
    assert_match(/size limit/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_each_role_rejects_oversized_regular_files_before_opening_them
    load_subject
    NativeSimulatorSession::Plan::FILE_LIMITS.each do |role, limit|
      path = File.join(@directory, "oversized-#{role}")
      File.open(path, "wb") { |file| file.truncate(limit + 1) }
      with_method(File, :open, ->(*) { flunk "Oversized #{role} was opened" }) do
        error = assert_raises(NativeSimulatorSession::Stop) do
          NativeSimulatorSession::Plan.read_identity(path, limit: limit, deadline: NativeSimulatorSession.now + 2)
        end
        assert_match(/size limit/, error.message)
      end
    end
    assert_empty operations
  end

  def test_exact_role_boundaries_are_hashed_and_capture_the_same_bytes
    load_subject
    NativeSimulatorSession::Plan::FILE_LIMITS.each do |role, limit|
      path = File.join(@directory, "boundary-#{role}")
      File.open(path, "wb") { |file| file.truncate(limit) }
      identity, contents = NativeSimulatorSession::Plan.read_identity(path, limit: limit,
        deadline: NativeSimulatorSession.now + 5, capture: true)
      assert_equal limit, contents.bytesize
      assert_equal Digest::SHA256.hexdigest(contents), identity.last
    end
  end

  def test_plan_and_manifest_are_not_reopened_for_unbounded_parsing
    load_subject
    with_method(File, :read, ->(*) { flunk "Plan or manifest was reopened for parsing" }) do
      assert NativeSimulatorSession::Plan.new(@plan_path).verify!
    end
  end

  def test_identity_rejects_symlinks_directories_and_fifos_without_opening_them
    load_subject
    link = File.join(@directory, "identity-link")
    fifo = File.join(@directory, "identity-fifo")
    File.symlink(@tool, link)
    File.mkfifo(fifo)
    with_method(File, :open, ->(*) { flunk "Nonregular identity was opened" }) do
      [link, @directory, fifo].each do |path|
        assert_raises(NativeSimulatorSession::Stop) do
          NativeSimulatorSession::Plan.read_identity(path, limit: 65_536, deadline: NativeSimulatorSession.now + 2)
        end
      end
    end
  end

  def test_replacement_between_lstat_and_open_is_rejected_before_read_and_closes_fd
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    replacement = path + ".replacement"
    File.write(replacement, File.read(path))
    original_open = File.method(:open)
    opened = nil
    intercept = lambda do |name, *arguments, &block|
      File.rename(replacement, path)
      original_open.call(name, *arguments) do |file|
        opened = file
        file.define_singleton_method(:read) { |*| raise "Replaced descriptor was read" }
        block.call(file)
      end
    end
    with_method(File, :open, intercept) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2, deadline: NativeSimulatorSession.now + 2)
      end
      assert_match(/before reading/, error.message)
    end
    assert opened.closed?
  end

  def test_fifo_replacement_between_lstat_and_open_is_bounded_and_closes_fd
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    ack_reader, ack_writer = IO.pipe
    resume_reader, resume_writer = IO.pipe
    result_path = File.join(@directory, "fifo-result.json")
    child = fork do
      ack_reader.close
      resume_writer.close
      original_open = File.method(:open)
      opened = nil
      result = {}
      intercept = lambda do |name, *arguments, &block|
        ack_writer.write("before-open\n")
        ack_writer.flush
        raise "Missing FIFO replacement acknowledgement" unless resume_reader.read(1) == "1"
        original_open.call(name, *arguments) do |file|
          opened = file
          file.define_singleton_method(:read) { |*| raise "FIFO descriptor was read" }
          block.call(file)
        end
      end
      begin
        with_method(File, :open, intercept) do
          NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2,
            deadline: NativeSimulatorSession.now + 2)
          result["reason"] = "Unexpected FIFO acceptance"
        end
      rescue NativeSimulatorSession::Stop => error
        result["reason"] = error.message
        result["closed"] = opened&.closed?
      rescue StandardError => error
        result["fixture_error"] = "#{error.class}: #{error.message}"
      ensure
        File.write(result_path, JSON.generate(result))
      end
      exit! 0
    end
    ack_writer.close
    resume_reader.close
    assert_equal "before-open\n", Timeout.timeout(12) { ack_reader.gets }
    File.unlink(path)
    File.mkfifo(path)
    resume_writer.write("1")
    resume_writer.close
    _, status = Timeout.timeout(3) { Process.waitpid2(child) }
    child = nil
    assert status.success?
    result = JSON.parse(File.read(result_path))
    refute result.key?("fixture_error"), result.inspect
    assert_match(/changed before reading/, result.fetch("reason"))
    assert_equal true, result["closed"]
    assert_empty operations
  ensure
    if child
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.waitpid(child) rescue Errno::ECHILD
    end
    [ack_reader, ack_writer, resume_reader, resume_writer].compact.each { |io| io.close unless io.closed? }
  end

  def test_in_place_change_during_read_is_rejected_and_closes_fd
    load_subject
    path = @plan.fetch("files").fetch("source").fetch("path")
    File.write(path, "a" * (2 * NativeSimulatorSession::Plan::CHUNK_BYTES))
    original_open = File.method(:open)
    opened = nil
    intercept = lambda do |name, *arguments, &block|
      original_open.call(name, *arguments) do |file|
        opened = file
        original_read = file.method(:read)
        changed = false
        file.define_singleton_method(:read) do |length|
          chunk = original_read.call(length)
          unless changed
            changed = true
            original_open.call(path, "r+b") { |writer| writer.write("b") }
          end
          chunk
        end
        block.call(file)
      end
    end
    with_method(File, :open, intercept) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(path, limit: 1024**2, deadline: NativeSimulatorSession.now + 2)
      end
      assert_match(/changed while hashing/, error.message)
    end
    assert opened.closed?
  end

  def test_validation_deadline_refuses_before_opening_any_artifact
    load_subject
    with_method(File, :open, ->(*) { flunk "Expired validation opened an artifact" }) do
      error = assert_raises(NativeSimulatorSession::Stop) do
        NativeSimulatorSession::Plan.read_identity(@plan_path, limit: 65_536, deadline: NativeSimulatorSession.now - 1)
      end
      assert_match(/deadline/, error.message)
    end
  end

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

  def test_failure_diagnostics_accepts_empty_owned_logs
    logs = File.join(@directory, ".session-logs-empty")
    FileUtils.mkdir_p(logs)
    empty_log = File.join(logs, "1-boot.log")
    File.write(empty_log, "")
    File.write(@report, JSON.generate("decision" => "deny", "reason" => "fake failure"))
    diagnostics = failure_diagnostics
    assert_includes diagnostics, empty_log
    assert_includes diagnostics, "fake failure"
  end

  def test_production_entry_is_quarantined_before_any_child_even_with_environment_override
    output, error, status = Open3.capture3(
      { "EPUB2MP3_ALLOW_INTEL_SIMULATOR" => "1", "SESSION_FIXTURE" => @directory },
      RUBY, SCRIPT, "--plan", @plan_path
    )
    assert_equal 75, status.exitstatus, output + error
    assert_match(/quarantin/i, error)
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_plan_rejects_explicit_test_bundle_outside_authorized_root_before_workers
    load_subject
    assert_instance_of NativeSimulatorSession::Plan, NativeSimulatorSession::Plan.new(@plan_path)
    external = Dir.mktmpdir("simulator-external-bundle-")
    bundle = File.join(File.realpath(external), "ExternalTests.xctest")
    FileUtils.mkdir_p(bundle)
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key><string>#{bundle}</string></dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))

    error = assert_raises(NativeSimulatorSession::Stop) do
      NativeSimulatorSession::Plan.new(@plan_path)
    end
    assert_match(/TestBundlePath/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_accepts_testroot_bundle_and_rejects_symlink_escape_on_revalidation
    load_subject
    bundle = File.join(@directory, "OwnedTests.xctest")
    FileUtils.mkdir_p(bundle)
    external = Dir.mktmpdir("simulator-external-bundle-")
    external_bundle = File.join(File.realpath(external), "ExternalTests.xctest")
    FileUtils.mkdir_p(external_bundle)
    xctestrun = @plan.fetch("files").fetch("xctestrun")
    xml = File.read(xctestrun.fetch("path")).sub(
      "</dict></dict></plist>",
      "<key>TestBundlePath</key><string>__TESTROOT__/OwnedTests.xctest</string></dict></dict></plist>")
    File.write(xctestrun.fetch("path"), xml)
    xctestrun["sha256"] = Digest::SHA256.file(xctestrun.fetch("path")).hexdigest
    File.write(@plan_path, JSON.generate(@plan))
    plan = NativeSimulatorSession::Plan.new(@plan_path)
    assert_instance_of NativeSimulatorSession::Plan, plan

    Dir.rmdir(bundle)
    File.symlink(external_bundle, bundle)
    error = assert_raises(NativeSimulatorSession::Stop) { plan.verify! }
    assert_match(/TestBundlePath/, error.message)
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_rejects_testroot_traversal_to_existing_external_bundle
    load_subject
    external = Dir.mktmpdir("simulator-external-bundle-", File.dirname(@directory))
    FileUtils.mkdir_p(File.join(external, "ExternalTests.xctest"))
    reference = "__TESTROOT__/../#{File.basename(external)}/ExternalTests.xctest"
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string>#{reference}</string>")
    end
    assert_equal "TestBundlePath must be a directory inside source root", error.message
    assert_empty operations
    refute File.exist?(@lease)
  ensure
    FileUtils.remove_entry(external) if external && File.directory?(external)
  end

  def test_plan_rejects_unsupported_test_bundle_placeholder
    load_subject
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string>__TESTHOST__/X.xctest</string>")
    end
    assert_equal "Unsupported TestBundlePath reference", error.message
    assert_empty operations
    refute File.exist?(@lease)
  end

  def test_plan_rejects_empty_test_bundle_value
    load_subject
    error = assert_raises(NativeSimulatorSession::Stop) do
      plan_with_test_bundle_xml("<string/>")
    end
    assert_equal "Invalid TestBundlePath", error.message
    assert_empty operations
    refute File.exist?(@lease)
  end

  def fixture_process_identity(pid)
    fields = File.read("/proc/#{pid}/stat").sub(/\A.*\) /, "").split
    return nil if fields.first == "Z"
    [pid, Integer(fields.fetch(2)), fields.fetch(19)]
  rescue Errno::ENOENT
    nil
  end

  def test_owner_loss_after_final_inspection_before_boot_spawn_never_starts_cleanup
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    @plan["phase_timeout_seconds"] = 5.0
    File.write(@plan_path, JSON.generate(@plan))
    baseline = @plan.fetch("files").transform_values { |entry| File.binread(entry.fetch("path")) }
    ready_reader, ready_writer = IO.pipe
    resume_reader, resume_writer = IO.pipe
    backend = FakeBackend.new(@directory)
    original_environment = backend.method(:environment)
    backend.define_singleton_method(:environment) do |phase, plan|
      if phase == :boot
        ready_writer.write("before-boot-spawn\n")
        ready_writer.flush
        raise "Missing preboot acknowledgement" unless resume_reader.read(1) == "1"
      end
      original_environment.call(phase, plan)
    end
    owner = fork do
      ready_reader.close
      resume_writer.close
      run_session(backend: backend)
      exit! 0
    end
    ready_writer.close
    resume_reader.close
    assert_equal "before-boot-spawn\n", Timeout.timeout(12) { ready_reader.gets }, failure_diagnostics
    snapshot = JSON.parse(File.read(@report))
    assert_equal owner, snapshot.fetch("owner_pid")
    caretaker = snapshot.fetch("caretaker_pid")
    owned = [caretaker, *snapshot.fetch("process_groups")].map { |pid| fixture_process_identity(pid) }
    assert owned.all?, "All fixture processes must be authenticated before owner loss"
    # Reaping this owner guarantees its only owner-pipe writer is closed.
    Process.kill("KILL", owner)
    Process.waitpid(owner)
    owner = nil
    resume_writer.write("1")
    resume_writer.close
    report = wait_for_fixture do
      value = read_fixture_json(@report)
      value if value&.key?("elapsed_seconds")
    end
    wait_for_fixture do
      owned.all? { |identity| fixture_process_identity(identity.first) != identity }
    end
    assert_equal ["inspect", "inspect"], operations.map { |operation| operation.fetch("phase") }
    assert_equal "deny", report.fetch("decision")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/owner disappeared or cancelled/, report.fetch("reason"))
    baseline.each do |role, bytes|
      assert_equal bytes, File.binread(@plan.fetch("files").fetch(role).fetch("path"))
    end
    File.open(@lease, "a+") do |lease|
      wait_for_fixture { lease.flock(File::LOCK_EX | File::LOCK_NB) }
    end
  ensure
    [ready_reader, ready_writer, resume_reader, resume_writer].compact.each { |io| io.close unless io.closed? }
    if owner
      Process.kill("KILL", owner) rescue Errno::ESRCH
      Process.waitpid(owner) rescue Errno::ECHILD
    end
    # Recheck the recorded process birth before fallback signaling.
    (owned || []).compact.each do |identity|
      pid, group, = identity
      next unless fixture_process_identity(pid) == identity
      Process.kill("KILL", group == pid ? -pid : pid) rescue Errno::ESRCH
    end
  end

  def test_boot_spawn_refusal_never_starts_cleanup_or_changes_baseline
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    backend = FakeBackend.new(@directory)
    original_argv = backend.method(:argv)
    missing = File.join(@directory, "missing-boot-executable")
    backend.define_singleton_method(:argv) do |phase, plan|
      phase == :boot ? [missing] : original_argv.call(phase, plan)
    end
    baseline = @plan.fetch("files").transform_values { |entry| File.binread(entry.fetch("path")) }
    assert_equal 75, run_session(backend: backend), failure_diagnostics
    assert_equal ["inspect", "inspect"], operations.map { |operation| operation.fetch("phase") }
    report = JSON.parse(File.read(@report))
    assert_equal false, report.fetch("cleanup_verified")
    assert_equal "deny", report.fetch("decision")
    assert_includes report.fetch("reason"), "missing-boot-executable"
    baseline.each do |role, bytes|
      assert_equal bytes, File.binread(@plan.fetch("files").fetch(role).fetch("path"))
    end
  end

  def test_started_boot_failure_still_cleans_up_its_owned_marker
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    baseline = @plan.fetch("files").transform_values { |entry| File.binread(entry.fetch("path")) }
    assert_equal 75, run_session(mode: "boot_failure_after_start"), failure_diagnostics
    phases = operations.map { |operation| operation.fetch("phase") }.reject { |phase| phase == "inspect" }
    assert_equal %w[boot terminate shutdown quit verify], phases
    report = JSON.parse(File.read(@report))
    assert_equal true, report.fetch("cleanup_verified")
    assert_equal "deny", report.fetch("decision")
    assert_match(/boot failed with status 19/, report.fetch("reason"))
    refute File.exist?(File.join(@directory, "booted"))
    baseline.each do |role, bytes|
      assert_equal bytes, File.binread(@plan.fetch("files").fetch(role).fetch("path"))
    end
  end

  def test_success_orders_fixed_phases_and_confirms_cleanup_before_releasing_lease
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session
    assert_equal 0, result, failure_diagnostics
    phases = operations.map { |row| row.fetch("phase") }
    assert_equal %w[boot install test terminate shutdown quit verify], phases.reject { |phase| phase == "inspect" }
    assert_equal 8, phases.count("inspect"), "Target identity must be inspected again before every phase"
    report = JSON.parse(File.read(@report))
    assert_equal "allow", report.fetch("decision")
    assert_equal true, report.fetch("cleanup_verified")
    assert_equal 2, report.fetch("process_groups").length
    group = ->(phase) { operations.find { |row| row["phase"] == phase }.fetch("pgid") }
    assert_equal group.call("boot"), group.call("test")
    assert_equal group.call("terminate"), group.call("verify")
    refute_equal group.call("test"), group.call("verify")
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_resource_denial_first_received_during_cleanup_preserves_denied_outcome
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session(mode: "cleanup_resource_deny")
    report = JSON.parse(File.read(@report))
    assert_equal true, report.fetch("cleanup_verified"), failure_diagnostics
    assert_includes operations.map { |row| row.fetch("phase") }, "verify"
    assert_equal 75, result, failure_diagnostics
    assert_equal "deny", report.fetch("decision")
    assert_equal "Resource monitor denied session", report.fetch("reason")
    File.open(@lease, "a+") { |lease| assert lease.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_owner_sigkill_leaves_caretaker_to_confirm_cleanup_and_release_descendant_lease
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, _caretaker, worker, _result_path|
      Process.kill("KILL", owner)
      Process.waitpid(owner)
      report = wait_for_fixture do
        value = read_fixture_json(@report)
        value if value && value["cleanup_verified"] == true
      end
      assert_equal "deny", report.fetch("decision")
      assert_match(/owner disappeared or cancelled/, report.fetch("reason"))
      assert_includes operations.map { |row| row.fetch("phase") }, "verify"
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  def test_caretaker_sigkill_terminates_owned_descendants_and_reports_incomplete_cleanup
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, caretaker, worker, result_path|
      Process.kill("KILL", caretaker)
      result = wait_for_fixture { read_fixture_json(result_path) }
      Process.waitpid(owner)
      assert_equal 75, result.fetch("result")
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match(/Caretaker lost; cleanup incomplete/, report.fetch("reason"))
      refute_includes operations.map { |row| row.fetch("phase") }, "shutdown"
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  def test_owner_sigterm_cancels_work_and_confirms_cleanup_before_returning_signal_status
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    with_held_session do |owner, _caretaker, worker, result_path|
      Process.kill("TERM", owner)
      result = wait_for_fixture { read_fixture_json(result_path) }
      Process.waitpid(owner)
      assert_equal 143, result.fetch("result")
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal true, report.fetch("cleanup_verified"), failure_diagnostics
      assert_match(/owner disappeared or cancelled/, report.fetch("reason"))
      assert_workers_stopped_and_lease_released(worker)
    end
  end

  {
    "old_start_with_fresh_finish_and_zero_duration" => [-100.0, 0.0],
    "actual_collection_exceeds_budget" => [-6.0, 5.0],
    "declared_duration_disagrees_with_elapsed_collection" => [-0.25, 0.0],
    "collection_starts_after_its_finish" => [1.0, 0.0]
  }.each do |name, (start_offset, declared_duration)|
    define_method("test_monitor_rejects_#{name}") do
      load_subject
      reader, writer = IO.pipe
      monitor = NativeSimulatorSession::Monitor.new(reader, StringIO.new, 15.0)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      started = start_offset == -100.0 ? now - [100.0, now / 2].min : now + start_offset
      policy = { "event" => "policy", "limits" => NativeSimulatorSession::Monitor::LIMITS,
                 "load1_limit" => "min(6.0, 0.75 * logical_cpus)",
                 "duration_seconds" => 15.0, "interval_seconds" => 0.1 }
      sample = { "event" => "sample", "decision" => "allow", "reasons" => [],
                 "sample" => { "started_monotonic" => started,
                   "collected_monotonic" => now, "collection_seconds" => declared_duration,
                   "memory_bytes" => 8 * 1024**3, "logical_cpus" => 8,
                   "memory_free_percent" => 58, "disk_free_bytes" => 12 * 1024**3,
                   "swap_used_bytes" => 0, "load_averages" => [1.0, 1.0, 1.0],
                   "panic_identities" => [] } }
      writer.write(JSON.generate(policy) + "\n" + JSON.generate(sample) + "\n")
      writer.flush
      # Keep the producer open: EOF must not accidentally satisfy this denial.
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/Invalid or replayed resource sample/, error.message)
    ensure
      reader&.close
      writer&.close
    end
  end

  def test_old_collection_start_prevents_any_session_phase_from_launching
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    result = run_session(mode: "old_collection_start")
    assert_equal 75, result, failure_diagnostics
    assert_empty operations
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/Invalid or replayed resource sample/, report.fetch("reason"))
  end

  def test_monitor_rejects_changed_resource_policy
    with_monitor_fixture(policy_changes: { "limits" => {} }) do |monitor|
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/policy mismatch/, error.message)
    end
  end

  def test_operation_excludes_ambient_environment_and_preserves_explicit_values_and_real_lease
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    sentinel = "EPUB_SESSION_AMBIENT_TEST_ONLY"
    previous_sentinel = ENV[sentinel]
    ENV[sentinel] = "owned harmless fixture"
    program = <<~'RUBY'
      require "json"
      descriptor = ENV.fetch("EPUB_NATIVE_LEASE_FD")
      lease_path = ENV.fetch("EPUB_NATIVE_LEASE_PATH")
      handle = File.for_fd(Integer(descriptor), autoclose: false)
      actual = handle.stat
      expected = File.stat(lease_path)
      held = File.open(lease_path, "a+") { |probe| !probe.flock(File::LOCK_EX | File::LOCK_NB) }
      puts JSON.generate(
        "ambient_present" => ENV.key?("EPUB_SESSION_AMBIENT_TEST_ONLY"),
        "explicit_value" => ENV["EPUB_SESSION_EXPLICIT_TEST"],
        "path_matches" => ENV["PATH"] == ARGV.fetch(0),
        "locale" => ENV["LC_ALL"], "lease_descriptor" => descriptor,
        "lease_path_matches" => lease_path == ARGV.fetch(1),
        "lease_identity_matches" => actual.file? && [actual.dev, actual.ino] == [expected.dev, expected.ino],
        "lease_held" => held)
    RUBY
    command = [RUBY, "-e", program, ENV.fetch("PATH"), @lease]
    backend = FakeBackend.new(@directory)
    backend.define_singleton_method(:argv) { |_phase, _plan| command }
    backend.define_singleton_method(:environment) do |_phase, _plan|
      { "EPUB_SESSION_EXPLICIT_TEST" => "owned explicit fixture" }
    end
    lease, inherited = NativeJob.lease(@lease)
    caretaker = NativeSimulatorSession::Caretaker.new(
      NativeSimulatorSession::Plan.new(@plan_path), backend, lease, @lease,
      [], nil, NativeSimulatorSession::Report.new(@report), NativeSimulatorSession.now)
    child = nil
    output_path = File.join(@directory, "operation-environment.json")
    File.open(output_path, "w+") do |output|
      child = caretaker.spawn_operation(:test, true, out: output, err: output,
        deadline: NativeSimulatorSession.now + 2, cleanup: true)
      _, status = Timeout.timeout(5) { Process.waitpid2(child) }
      child = nil
      assert status.success?, "Owned environment fixture failed"
      output.rewind
      observed = JSON.parse(output.read)
      assert_equal false, observed.fetch("ambient_present")
      assert_equal "owned explicit fixture", observed.fetch("explicit_value")
      assert_equal true, observed.fetch("path_matches")
      assert_equal "C", observed.fetch("locale")
      assert_equal NativeJob::CHILD_FD.to_s, observed.fetch("lease_descriptor")
      assert_equal true, observed.fetch("lease_path_matches")
      assert_equal true, observed.fetch("lease_identity_matches")
      assert_equal true, observed.fetch("lease_held")
    end
  ensure
    if sentinel
      if previous_sentinel.nil?
        ENV.delete(sentinel)
      else
        ENV[sentinel] = previous_sentinel
      end
    end
    if child
      Process.kill("KILL", -child) rescue Errno::ESRCH
      Process.waitpid(child) rescue Errno::ECHILD
    end
    lease&.close unless inherited
  end

  def test_singleton_backend_command_is_a_literal_executable_without_shell_expansion
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    load_subject
    marker = File.join(@directory, "shell-expanded")
    command = "printf owned > #{Shellwords.escape(marker)}"
    backend = FakeBackend.new(@directory)
    backend.define_singleton_method(:argv) { |_phase, _plan| [command] }
    lease, inherited = NativeJob.lease(@lease)
    caretaker = NativeSimulatorSession::Caretaker.new(
      NativeSimulatorSession::Plan.new(@plan_path), backend, lease, @lease,
      [], nil, NativeSimulatorSession::Report.new(@report), NativeSimulatorSession.now)
    rejected = nil
    spawned = false
    child = nil
    begin
      File.open(File::NULL, "w") do |sink|
        child = caretaker.spawn_operation(:test, true, out: sink, err: sink,
          deadline: NativeSimulatorSession.now + 2, cleanup: true)
        spawned = true
        wait_for_fixture { Process.waitpid(child, Process::WNOHANG) }
      end
    rescue Errno::ENOENT => error
      rejected = error
    end
    refute File.exist?(marker), "The singleton executable string must never be interpreted by a shell"
    refute spawned, "No shell child may be accepted for a missing literal executable"
    assert_instance_of Errno::ENOENT, rejected
  ensure
    if child
      begin
        if Process.waitpid(child, Process::WNOHANG).nil?
          Process.kill("KILL", -child)
          Process.waitpid(child)
        end
      rescue Errno::ECHILD
        nil
      end
    end
    lease&.close unless inherited
  end

  def test_monitor_rejects_stale_sample_even_when_collection_duration_is_valid
    finished = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 6
    with_monitor_fixture(sample_changes: { "started_monotonic" => finished, "collected_monotonic" => finished }) do |monitor|
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/sample is stale/, error.message)
    end
  end

  { "monitor_eof" => /ended unexpectedly/, "initial_resource_deny" => /denied session/ }.each do |mode, reason|
    define_method("test_#{mode}_prevents_any_owned_phase") do
      skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
      assert_equal 75, run_session(mode: mode), failure_diagnostics
      assert_empty operations
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match reason, report.fetch("reason")
    end
  end

  def test_new_panic_stops_owned_groups_without_starting_fresh_cleanup_commands
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    assert_equal 75, run_session(mode: "panic_during_test"), failure_diagnostics
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal true, report.fetch("fatal_panic")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/New panic report detected/, report.fetch("reason"))
    phases = operations.map { |row| row.fetch("phase") }
    assert_equal "test", phases.last
    %w[terminate shutdown quit verify].each { |phase| refute_includes phases, phase }
    worker = read_fixture_json(File.join(@directory, "worker-ready.json"))
    assert_equal report.fetch("process_groups").first, worker.fetch("pgid")
    assert_workers_stopped_and_lease_released(worker)
  end

  def test_same_content_artifact_replacement_prevents_next_phase_and_cleanup_claim
    skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
    assert_equal 75, run_session(mode: "replace_artifact"), failure_diagnostics
    report = read_fixture_json(@report)
    assert_equal "deny", report.fetch("decision")
    assert_equal false, report.fetch("cleanup_verified")
    assert_match(/Artifact identity changed/, report.fetch("reason"))
    assert_match(/Artifact identity changed/, report.fetch("cleanup_error"))
    assert_equal "install", operations.last.fetch("phase")
    refute_includes operations.map { |row| row.fetch("phase") }, "test"
  end

  { "cleanup_failure" => /shutdown failed with status 19/,
    "cleanup_timeout" => /Session deadline exceeded/ }.each do |mode, reason|
    define_method("test_#{mode}_reports_incomplete_cleanup_and_bounded_failure") do
      skip "Injected process contracts run on Linux only" if RUBY_PLATFORM.include?("darwin")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 75, run_session(mode: mode), failure_diagnostics
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 16.5
      report = read_fixture_json(@report)
      assert_equal "deny", report.fetch("decision")
      assert_equal false, report.fetch("cleanup_verified")
      assert_match reason, report.fetch("cleanup_error")
      refute_includes operations.map { |row| row.fetch("phase") }, "verify"
      if mode == "cleanup_timeout"
        worker = read_fixture_json(File.join(@directory, "cleanup-worker.json"))
        assert_equal report.fetch("process_groups").last, worker.fetch("pgid")
        assert_workers_stopped_and_lease_released(worker)
      end
    end
  end
end
