# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "native_build_preflight"

class NativeBuildPreflightTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus == 0
  end

  def check(states: [], metal: 1, app: 1, sim: 0, raw: nil)
    calls = []
    runner = lambda do |*args|
      calls << args
      if args.first == "xcrun"
        [raw || JSON.generate("devices" => { "runtime" => states.map { |s| { "state" => s } } }), "", Status.new(sim)]
      elsif args.last == "SimMetalHost"
        ["", "", Status.new(metal)]
      else
        ["", "", Status.new(app)]
      end
    end
    result = NativeBuildPreflight.check(host: "x86_64-darwin24", runner: runner)
    [result, calls]
  end

  def test_shutdown_and_absent_metal_allow_build
    result, calls = check(states: ["Shutdown"])
    assert_nil result
    assert_equal ["pgrep", "-f", "SimMetalHost"], calls[-2]
    assert_equal ["pgrep", "-f", "/Simulator[.]app/Contents/MacOS/Simulator($| )"], calls.last
    assert_nil check.first
  end

  def test_boot_and_incomplete_shutdown_block_before_process_query
    ["Booted", "Booting", "Shutting Down", "Creating"].each do |state|
      result, calls = check(states: ["Shutdown", state])
      assert_match(/Shut down/, result)
      assert_equal 1, calls.length
    end
  end

  def test_lingering_metal_blocks_after_shutdown
    assert_match(/SimMetalHost to exit/, check(states: ["Shutdown"], metal: 0).first)
  end

  def test_inspection_failures_block
    assert_match(/blocked/, check(sim: 1).first)
    assert_match(/blocked/, check(metal: 2).first)
    ["{", "{}", "null", "[]", '{"devices":[]}', '{"devices":{"runtime":[{}]}}'].each do |raw|
      assert_match(/blocked/, check(raw: raw).first)
    end
    assert_match(/blocked/, NativeBuildPreflight.check(host: "x86_64-darwin", runner: ->(*) { raise Errno::ENOENT }))
  end

  def test_open_simulator_app_or_failed_inspection_blocks_build
    assert_match(/Quit Simulator.app/, check(states: ["Shutdown"], app: 0).first)
    assert_match(/Cannot inspect Simulator.app/, check(states: ["Shutdown"], app: 2).first)
  end

  def test_other_hosts_do_not_inspect_apple_services
    ["arm64-darwin24", "x86_64-linux"].each do |host|
      assert_nil NativeBuildPreflight.check(host: host, runner: ->(*) { flunk "unexpected command" })
    end
  end
end
