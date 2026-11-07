# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "simulator_session"

class SimulatorSessionTest < Minitest::Test
  class Backend
    attr_reader :calls
    attr_accessor :failure, :pending, :identity_error, :cleanup_error
    def initialize
      @calls = []
    end
    def inspect_identity
      raise "wrong runtime" if identity_error
      { "fixture" => true }
    end
    def recheck; end
    def recheck_idle; end
    def start(stage)
      @calls << stage
    end
    def poll
      return nil if pending
      failure || 0
    end
    def cleanup
      @calls << :cleanup
      raise "shutdown not verified" if cleanup_error
      "verified_shutdown"
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @report = File.join(@dir, "report.json")
    @reader, @writer = IO.pipe
    @writer.write(".")
    @backend = Backend.new
    @sample = { "pressure" => 1, "free_percent" => 60, "swap_mib" => 200, "swapouts" => 50,
                "compressed_bytes" => 1024, "cpu_idle" => 90, "free_bytes" => 30 * 1024**3 }
  end

  def teardown
    @reader.close unless @reader.closed?
    @writer.close unless @writer.closed?
    FileUtils.remove_entry(@dir)
  end

  def run_session(**options)
    # Non-timeout cases must tolerate CI scheduling and report writes.
    # Timeout cases select their short deadline explicitly.
    supervisor = SimulatorSession::Supervisor.new(backend: @backend, sampler: -> { @sample },
      report: @report, heartbeat: @reader, lease_path: File.join(@dir, "lock"),
      baseline_seconds: 0, interval: 0.01, journey_seconds: 0, session_seconds: 1, boot_seconds: 1, **options)
    supervisor.run
    [supervisor, JSON.parse(File.read(@report))]
  end

  def test_success_always_shuts_down_and_records_final_resources
    supervisor, report = run_session
    assert supervisor.successful?
    assert_equal [:boot, :ready, :ui, :install, :launch, :cleanup], @backend.calls
    assert_equal "verified_shutdown", report["cleanup"]
    assert_equal @sample, report["final_resources"]
  end

  def test_selected_test_runs_under_watchdog_and_requires_cleanup
    @backend.define_singleton_method(:test_session?) { true }
    supervisor, report = run_session(observe_resources: true)
    assert supervisor.successful?
    assert_equal [:boot, :ready, :ui, :install, :launch, :test, :cleanup], @backend.calls
    assert_equal 'test_command_completed', report['result']
    assert_equal 'verified_shutdown', report['cleanup']
  end

  def test_selected_test_failure_preserves_failure_and_cleans_up
    @backend.define_singleton_method(:test_session?) { true }
    @backend.define_singleton_method(:poll) { @calls.last == :test ? 65 : 0 }
    supervisor, report = run_session(observe_resources: true)
    refute supervisor.successful?
    assert_match(/test failed \(65\)/, report['error'])
    assert_equal :cleanup, @backend.calls.last
  end

  def test_admission_failure_never_boots_or_shuts_down_unowned_device
    @sample["cpu_idle"] = 10
    supervisor, report = run_session
    refute supervisor.successful?
    assert_empty @backend.calls
    assert_match(/CPU/, report["error"])
  end

  def test_identity_failure_never_boots
    @backend.identity_error = true
    supervisor, report = run_session
    refute supervisor.successful?
    assert_empty @backend.calls
    assert_match(/runtime/, report["error"])
  end

  def test_command_failure_and_timeout_both_clean_up
    @backend.failure = 23
    supervisor, report = run_session
    refute supervisor.successful?
    assert_equal [:boot, :cleanup], @backend.calls
    assert_match(/23/, report["error"])
    File.delete(@report)
    @backend = Backend.new
    @backend.pending = true
    _, report = run_session(boot_seconds: 0.02)
    assert_match(/deadline/, report["error"])
    assert_equal [:boot, :cleanup], @backend.calls
  end

  def test_parent_eof_and_cancellation_refuse_before_boot
    @writer.close
    _, report = run_session
    assert_match(/Foreground exited/, report["error"])
    assert_empty @backend.calls
    File.delete(@report)
    @reader.close
    @reader, @writer = IO.pipe
    @writer.write("!")
    _, report = run_session
    assert_match(/cancelled/, report["error"])
    assert_empty @backend.calls
  end

  def test_cleanup_failure_is_not_a_success
    @backend.cleanup_error = true
    supervisor, report = run_session
    refute supervisor.successful?
    assert_equal "cleanup_failed", report["result"]
  end

  def test_explicit_observation_retains_cleanup_and_records_phase_and_limits
    @sample.merge!('swap_mib' => 3000, 'cpu_idle' => 20, 'free_percent' => 30)
    supervisor, report = run_session(observe_resources: true)
    assert supervisor.successful?
    assert_equal 'explicit_resource_observation', report['admission_policy']
    assert_equal 'verified_shutdown', report['cleanup']
    assert_equal 0, report['limits']['app_seconds']
    assert report['samples'].all? { |row| row.key?('phase') }
  end

  def test_default_refuses_existing_swap_but_explicit_mode_records_its_policy
    @sample["swap_mib"] = 2300
    _, report = run_session
    assert_empty @backend.calls
    assert_match(/1 GiB/, report["error"])
    assert_equal "strict_1gib_swap", report["admission_policy"]
    File.delete(@report)
    supervisor, report = run_session(stable_existing_swap: true)
    assert supervisor.successful?
    assert_equal "explicit_stable_existing_swap", report["admission_policy"]
  end

  def test_swap_regrowth_at_final_preboot_sample_blocks_even_below_initial_swap
    values = [2300, 2100, 2200]
    sampler = -> { @sample.merge("swap_mib" => values.shift || 2200) }
    _, report = run_session(stable_existing_swap: true, sampler: sampler)
    assert_empty @backend.calls
    assert_match(/grew/, report["error"])
  end

  def test_prepare_refusal_prevents_install_and_cleans_up
    @backend.define_singleton_method(:prepare) do |stage|
      raise SimulatorResources::Refusal, "changed app" if stage == :install
    end
    _, report = run_session
    assert_equal [:boot, :ready, :ui, :cleanup], @backend.calls
    assert_match(/changed app/, report["error"])
  end

  def test_critical_pressure_after_boot_stops_and_cleans_up
    @backend.pending = true
    calls = 0
    sampler = lambda do
      calls += 1
      calls <= 3 ? @sample : @sample.merge("pressure" => 4)
    end
    _, report = run_session(sampler: sampler)
    assert_match(/Critical/, report["error"])
    assert_equal [:boot, :cleanup], @backend.calls
  end
def test_lease_conflict_never_inspects_or_boots
  File.open(File.join(@dir, "lock"), "w") do |lock|
    lock.flock(File::LOCK_EX)
    supervisor = SimulatorSession::Supervisor.new(backend: @backend, sampler: -> { @sample }, report: @report,
      heartbeat: @reader, lease_path: File.join(@dir, "lock"))
    supervisor.run
    refute supervisor.successful?
    assert_empty @backend.calls
  end
end

def test_parent_death_during_boot_is_detected_by_detached_watchdog
  @backend.pending = true
  parent = fork do
    SimulatorSession.launch(backend: @backend, sampler: -> { @sample }, report: @report,
      lease_path: File.join(@dir, "lock"), baseline_seconds: 0, interval: 0.01,
      session_seconds: 5, boot_seconds: 4, journey_seconds: 0)
    exit! 0
  end
  Timeout.timeout(3) do
    loop do
      if File.exist?(@report)
        report = JSON.parse(File.read(@report))
        break if report["events"].any? { |event| event["event"] == "boot" }
      end
      sleep 0.01
    end
  end
  Process.kill("KILL", parent)
  Process.waitpid(parent)
  parent = nil
  Timeout.timeout(3) do
    sleep 0.02 until JSON.parse(File.read(@report))["cleanup"]
  end
  report = JSON.parse(File.read(@report))
  assert_equal "verified_shutdown", report["cleanup"]
  assert_match(/Foreground exited/, report["error"])
  Timeout.timeout(2) do
    loop do
      acquired = File.open(File.join(@dir, "lock"), "a+") { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
      break if acquired
      sleep 0.01
    end
  end
ensure
  if parent
    Process.kill("KILL", parent) rescue Errno::ESRCH
    Process.waitpid(parent) rescue Errno::ECHILD
  end
end

def test_lost_heartbeat_without_eof_refuses
  supervisor = SimulatorSession::Supervisor.new(backend: @backend, sampler: -> { @sample },
    report: @report, heartbeat: @reader, clock: -> { 20 })
  @reader.read_nonblock(4096)
  supervisor.instance_variable_set(:@last_heartbeat, 0)
  assert_raises(SimulatorResources::Refusal) { supervisor.check_heartbeat }
end

def test_deadline_is_checked_before_accepting_completed_command
  now = 0.0
  supervisor = SimulatorSession::Supervisor.new(backend: @backend, sampler: -> { @sample },
    report: @report, heartbeat: @reader, clock: -> { now })
  supervisor.instance_variable_set(:@deadline, 100)
  supervisor.instance_variable_set(:@next_sample, 100)
  @backend.define_singleton_method(:poll) { 0 }
  calls = 0
  supervisor.define_singleton_method(:watch) { calls += 1; now = 2 if calls == 2 }
  assert_raises(SimulatorResources::Refusal) { supervisor.command(:install, timeout: 1) }
end

def test_warning_in_last_preboot_sample_refuses_without_boot
  calls = 0
  sampler = lambda do
    calls += 1
    calls == 3 ? @sample.merge("pressure" => 2) : @sample
  end
  _, report = run_session(sampler: sampler)
  assert_empty @backend.calls
  assert_match(/not normal/, report["error"])
end

def test_cancellation_received_during_sampling_refuses_before_boot
  calls = 0
  sampler = lambda do
    calls += 1
    @writer.write("!") if calls == 3
    @sample
  end
  _, report = run_session(sampler: sampler)
  assert_empty @backend.calls
  assert_match(/cancelled/, report["error"])
end

end
