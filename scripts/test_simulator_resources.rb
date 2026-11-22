# frozen_string_literal: true
require "minitest/autorun"
require_relative "simulator_cpu_idle"
require_relative "simulator_resources"
require "tmpdir"

class SimulatorResourcesTest < Minitest::Test
  def sample
    { "pressure" => 1, "free_percent" => 60, "swap_mib" => 200, "swapouts" => 50,
      "compressed_bytes" => 1024, "cpu_idle" => 90, "free_bytes" => 30 * 1024**3 }
  end

  def test_every_former_admission_reading_is_only_a_note
    assert_empty SimulatorResources.notes(sample)
    [["pressure", 2, /warning/], ["free_percent", 39, /free memory 39%/], ["swap_mib", 1025, /Swap 1025 MiB/],
     ["cpu_idle", 69, /CPU idle 69%/], ["free_bytes", 15 * 1024**3 - 1, /Free disk below 15 GiB/]].each do |key, value, expected|
      notes = SimulatorResources.notes(sample.merge(key => value))
      assert_equal 1, notes.length, key
      assert_match(expected, notes.first, key)
    end
    assert_match(/critical/, SimulatorResources.notes(sample.merge("pressure" => 4)).first)
    at_floor = sample.merge("free_bytes" => 15 * 1024**3)
    assert_empty SimulatorResources.notes(at_floor), "the disk reference size is inclusive"
  end

  def test_the_admission_api_is_gone
    %i[admission disk_refusal].each { |name| refute_respond_to SimulatorResources, name }
    refute SimulatorResources.const_defined?(:Monitor, false)
    refute Object.const_defined?(:SimulatorPreflight)
  end

  def test_missing_nan_and_out_of_range_telemetry_is_rejected_as_a_reading
    [sample.reject { |key, _| key == "swapouts" }, sample.merge("cpu_idle" => Float::NAN),
     sample.merge("pressure" => 0), sample.merge("free_percent" => 101)].each do |invalid|
      assert_raises(SimulatorResources::Refusal) { SimulatorResources.validate(invalid) }
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

  def test_parser_uses_bounded_cpu_sampler_and_rejects_missing_fields
    outputs = ["1", "System-wide memory free percentage: 55%", "total = 10M used = 2.5M free = 7.5M",
               "page size of 4096 bytes\nSwapouts: 12.\nPages occupied by compressor: 100.",
               "88.4\n", "header\ndisk 400 100 300 0% /\n"]
    commands = []
    capture = lambda do |*argv, **options|
      commands << [argv, options]
      outputs.shift
    end
    snapshot = SimulatorResources.snapshot(root: "/", capture: capture)
    assert_equal 88.4, snapshot["cpu_idle"]
    helper = File.expand_path("simulator_cpu_idle.rb", __dir__)
    assert_equal [[RbConfig.ruby, helper], { seconds: 8 }], commands.fetch(4)
    assert_equal 2.5, snapshot["swap_mib"]
    assert_equal 300 * 1024, snapshot["free_bytes"]
    assert_raises(SimulatorResources::Refusal) do
      SimulatorResources.snapshot(root: "/", capture: ->(*) { "missing" })
    end
  end

  def test_cpu_idle_uses_the_interval_and_handles_counter_wrap
    assert_equal 70.0, SimulatorCPUIdle.percentage([10, 10, 10, 10], [20, 20, 80, 20])
    assert_in_delta(1000.0 / 12, SimulatorCPUIdle.percentage([0, 0, 0xfffffffa, 0], [1, 1, 4, 0]))
  end

  def test_cpu_idle_rejects_invalid_or_stalled_counters
    assert_raises(ArgumentError) { SimulatorCPUIdle.percentage([1, 2, 3], [1, 2, 3, 4]) }
    assert_raises(ArgumentError) { SimulatorCPUIdle.percentage([1, 2, 3, 4], [1, 2, 3, 4]) }
  end
end
