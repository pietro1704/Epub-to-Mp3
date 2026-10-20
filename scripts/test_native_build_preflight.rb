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
    assert_includes calls.last.last, "/Simulator[.]app/"
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

  def test_open_simulator_app_blocks_even_after_all_devices_and_metal_exit
    assert_match(/Quit Simulator.app/, check(states: ["Shutdown"], app: 0).first)
    assert_match(/Cannot inspect Simulator.app/, check(app: 2).first)
  end

  def test_simulator_process_expression_is_accepted_by_real_pgrep
    _, calls = check
    # Exercise the production expression against the host's POSIX ERE engine.
    # This only queries processes; it cannot start a Simulator or native build.
    _, error, status = Open3.capture3(*calls.last)
    assert_includes [0, 1], status.exitstatus, error
  end

  def test_inspection_failures_block
    assert_match(/blocked/, check(sim: 1).first)
    assert_match(/blocked/, check(metal: 2).first)
    ["{", "{}", "null", "[]", '{"devices":[]}', '{"devices":{"runtime":[{}]}}'].each do |raw|
      assert_match(/blocked/, check(raw: raw).first)
    end
    assert_match(/blocked/, NativeBuildPreflight.check(host: "x86_64-darwin", runner: ->(*) { raise Errno::ENOENT }))
  end

  def test_other_hosts_do_not_inspect_apple_services
    ["arm64-darwin24", "x86_64-linux"].each do |host|
      assert_nil NativeBuildPreflight.check(host: host, runner: ->(*) { flunk "unexpected command" })
    end
  end
end

class RepositoryPreflightTest < Minitest::Test
  def run_preflight(branch:, behind: false, suite_status: 0)
    Dir.mktmpdir("epub-preflight-test-") do |dir|
      git = File.join(dir, "git")
      File.write(git, <<~'SH')
        #!/bin/bash
        case "$1" in
          diff) exit 0 ;;
          branch) echo "$TEST_BRANCH" ;;
          show-ref) exit 1 ;;
          rev-parse) [[ "$3" == master ]] ;;
          merge-base) [[ "$3" == master && "$TEST_BEHIND" == 0 ]] ;;
          *) exit 99 ;;
        esac
      SH
      File.chmod(0o755, git)
      mise = File.join(dir, "mise")
      File.write(mise, "#!/bin/bash\nprintf '%s\\n' \"$*\" > \"$TEST_CALL_LOG\"\nexit \"$TEST_SUITE_STATUS\"\n")
      File.chmod(0o755, mise)
      calls = File.join(dir, "calls")
      env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "TEST_BRANCH" => branch,
              "TEST_BEHIND" => behind ? "1" : "0", "CI" => "false",
              "TEST_CALL_LOG" => calls, "TEST_SUITE_STATUS" => suite_status.to_s }
      result = Open3.capture3(env, "bash", File.expand_path("preflight.sh", __dir__))
      result + [File.exist?(calls) ? File.read(calls) : ""]
    end
  end

  def test_master_integration_accepts_current_feature
    output, error, status = run_preflight(branch: "feature/configuration")
    assert status.success?, error
    assert_match(/Branch: feature\/configuration/, output)
  end

  def test_master_and_behind_feature_are_rejected
    _, error, status = run_preflight(branch: "master")
    refute status.success?
    assert_match(/not 'master'/, error)
    _, error, status = run_preflight(branch: "feature/configuration", behind: true)
    refute status.success?
    assert_match(/behind master/, error)
  end

  def test_host_check_failure_stops_local_preflight_with_original_status
    _, _, status, calls = run_preflight(branch: "feature/configuration", suite_status: 17)
    assert_equal 17, status.exitstatus
    assert_equal "run host:workflow:test\n", calls
  end
end
