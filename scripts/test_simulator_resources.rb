# frozen_string_literal: true
require "minitest/autorun"
require_relative "simulator_resources"
require_relative "simulator_preflight"
require "tmpdir"

class SimulatorResourcesTest < Minitest::Test
  def sample
    { "pressure" => 1, "free_percent" => 60, "swap_mib" => 200, "swapouts" => 50,
      "compressed_bytes" => 1024, "cpu_idle" => 90, "free_bytes" => 30 * 1024**3 }
  end

  def test_admission_and_independent_failure_conditions
    assert_nil SimulatorResources.admission(sample, sample)
    { "pressure" => 2, "free_percent" => 39, "swap_mib" => 1025,
      "swapouts" => 51, "cpu_idle" => 69, "free_bytes" => 19 * 1024**3 }.each do |key, value|
      refute_nil SimulatorResources.admission(sample.merge(key => value), sample), key
    end
  end

  def test_missing_nan_and_out_of_range_telemetry_fail_closed
    [sample.reject { |key, _| key == "swapouts" }, sample.merge("cpu_idle" => Float::NAN),
     sample.merge("pressure" => 0), sample.merge("free_percent" => 101)].each do |invalid|
      assert_raises(SimulatorResources::Refusal) { SimulatorResources.validate(invalid) }
    end
  end

  def test_runtime_durations_and_recovery_reset
    monitor = SimulatorResources::Monitor.new(sample)
    low = sample.merge("cpu_idle" => 5)
    assert_nil monitor.check(low, 0)
    assert_nil monitor.check(low, 29)
    assert_nil monitor.check(sample, 30)
    assert_nil monitor.check(low, 31)
    assert_match(/CPU/, monitor.check(low, 61))
    assert_match(/Critical/, monitor.check(sample.merge("pressure" => 4), 62))
    assert_match(/disk/, monitor.check(sample.merge("free_bytes" => 0), 63))
  end

  def test_each_memory_threshold_is_sustained_for_ten_seconds
    [{ "pressure" => 2 }, { "free_percent" => 24 }, { "swap_mib" => 456 }].each do |change|
      monitor = SimulatorResources::Monitor.new(sample)
      assert_nil monitor.check(sample.merge(change), 0)
      assert_nil monitor.check(sample.merge(change), 9)
      refute_nil monitor.check(sample.merge(change), 10)
    end
  end

  def test_capture_timeout_kills_owned_process_group
    assert_raises(SimulatorResources::Refusal) do
      SimulatorResources.capture(RbConfig.ruby, "-e", "sleep 30", seconds: 0.05)
    end
  end

def test_timeout_includes_descendant_held_output_after_leader_exit
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  assert_raises(SimulatorResources::Refusal) do
    SimulatorResources.capture(RbConfig.ruby, "-e", "fork { sleep 20 }; exit", seconds: 0.1)
  end
  assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
end

def test_parser_uses_interval_cpu_and_rejects_missing_fields

    outputs = ["1", "System-wide memory free percentage: 55%", "total = 10M used = 2.5M free = 7.5M",
               "page size of 4096 bytes\nSwapouts: 12.\nPages occupied by compressor: 100.",
               "CPU usage: 0% idle\nCPU usage: 88.4% idle\n", "header\ndisk 400 100 300 0% /\n"]
    snapshot = SimulatorResources.snapshot(root: "/", capture: ->(*) { outputs.shift })
    assert_equal 88.4, snapshot["cpu_idle"]
    assert_equal 2.5, snapshot["swap_mib"]
    assert_equal 300 * 1024, snapshot["free_bytes"]
    assert_raises(SimulatorResources::Refusal) do
      SimulatorResources.snapshot(root: "/", capture: ->(*) { "missing" })
    end
  end

  def test_preflight_records_refusal_and_does_not_overwrite_evidence
    Dir.mktmpdir do |dir|
      report = File.join(dir, "report.json")
      result = SimulatorPreflight.run(report: report, seconds: 0, sampler: -> { sample.merge("swap_mib" => 2000) }, lock: File.join(dir, "lock"))
      refute result["admitted"]
      assert_match(/Swap/, JSON.parse(File.read(report))["refusal"])
      previous = File.read(report)
      SimulatorPreflight.run(report: report, seconds: 0, sampler: -> { sample }, lock: File.join(dir, "lock"))
      assert_equal previous, File.read(report)
    end
  end
end
