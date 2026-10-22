# frozen_string_literal: true

# Loaded by test_native_simulator_session.rb; preserve the existing suite selectors and fixture.
class NativeSimulatorSessionTest
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

  def test_monitor_rejects_stale_sample_even_when_collection_duration_is_valid
    finished = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 6
    with_monitor_fixture(sample_changes: { "started_monotonic" => finished, "collected_monotonic" => finished }) do |monitor|
      error = assert_raises(NativeSimulatorSession::Stop) { monitor.check! }
      assert_match(/sample is stale/, error.message)
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
end
