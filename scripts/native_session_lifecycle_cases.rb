# frozen_string_literal: true

# Loaded by test_native_simulator_session.rb; preserve the existing suite selectors and fixture.
class NativeSimulatorSessionTest
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
end
