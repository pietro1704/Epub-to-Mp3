# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "timeout"
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
    assert_equal ["pgrep", "-x", "SimMetalHost"], calls[-2]
    assert_equal ["pgrep", "-x", "Simulator"], calls.last
    assert_nil check.first
  end

  # Real pgrep against fixture names, so a Simulator on the host cannot change
  # the result. The command line of every decoy, and of this guard itself,
  # carries the name; only a process actually named like it may block.
  def real_processes(metal_host:, simulator_app:)
    shutdown = JSON.generate("devices" => { "runtime" => [{ "state" => "Shutdown" }] })
    runner = ->(*args) { args.first == "xcrun" ? [shutdown, "", Status.new(0)] : Open3.capture3(*args) }
    NativeBuildPreflight.check(host: "x86_64-darwin24", runner: runner, metal_host: metal_host, simulator_app: simulator_app)
  end

  def wait_until
    Timeout.timeout(10) { sleep 0.02 until yield }
  end

  def test_a_command_line_that_only_mentions_the_process_name_does_not_block
    name = "SMHfx#{Process.pid % 100_000}"
    absent = "#{name}no"
    decoy = Process.spawn(RbConfig.ruby, "-e", "sleep 30", "inspecting #{name} with grep")
    wait_until { system("pgrep", "-f", name, out: File::NULL) }
    assert system("pgrep", "-f", name, out: File::NULL), "the former command-line match sees the decoy"
    assert_nil real_processes(metal_host: name, simulator_app: absent)
    assert_nil real_processes(metal_host: absent, simulator_app: name)
    guard = "require ARGV[0]; s = Struct.new(:exitstatus) { def success? = exitstatus == 0 }; " \
            "r = ->(*a) { a.first == 'xcrun' ? ['{\"devices\":{}}', '', s.new(0)] : Open3.capture3(*a) }; " \
            "print NativeBuildPreflight.check(host: 'x86_64-darwin24', runner: r, metal_host: ARGV[1], simulator_app: ARGV[2]).inspect"
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", guard, File.expand_path("native_build_preflight.rb", __dir__), name, absent)
    assert status.success?, error
    assert_equal "nil", output, "the guard's own command line carries the name"
  ensure
    if decoy
      Process.kill("KILL", decoy) rescue Errno::ESRCH
      Process.waitpid(decoy) rescue Errno::ECHILD
    end
  end

  def test_a_process_named_exactly_like_the_simulator_host_or_app_blocks
    name = "SMHfx#{Process.pid % 100_000}"
    absent = "#{name}no"
    Dir.mktmpdir("preflight-process-") do |directory|
      executable = File.join(directory, name)
      FileUtils.ln_s(File.exist?("/bin/sleep") ? "/bin/sleep" : "/usr/bin/sleep", executable)
      process = Process.spawn(executable, "30")
      begin
        wait_until { system("pgrep", "-x", name, out: File::NULL) }
        assert_match(/SimMetalHost to exit/, real_processes(metal_host: name, simulator_app: absent))
        assert_match(/Quit Simulator.app/, real_processes(metal_host: absent, simulator_app: name))
      ensure
        Process.kill("KILL", process) rescue Errno::ESRCH
        Process.waitpid(process) rescue Errno::ECHILD
      end
      wait_until { !system("pgrep", "-x", name, out: File::NULL) }
      assert_nil real_processes(metal_host: name, simulator_app: absent)
    end
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

  def test_simulator_process_query_is_accepted_by_real_pgrep
    _, calls = check
    # Exercise the production query with the host's pgrep.
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
