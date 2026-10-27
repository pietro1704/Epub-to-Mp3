# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"
require_relative "native_job"

class NativeJobIntegrationTest < Minitest::Test
  SCRIPT = File.expand_path("native_job.rb", __dir__)
  RUBY = RbConfig.ruby

  def setup
    @dir = Dir.mktmpdir("native-job-")
    @lock = File.join(@dir, "lease")
    @marker = File.join(@dir, "child")
    @state = File.join(@dir, "state")
    File.write(@state, "Shutdown")
    write_command("xcrun", <<~'SH')
      #!/bin/bash
      [[ "$FAKE_SIM_FAILURE" == 1 ]] && exit 23
      printf '{"devices":{"test":[{"state":"%s"}]}}\n' "$(cat "$FAKE_STATE")"
    SH
    write_command("pgrep", "#!/bin/bash\nexit \"${FAKE_METAL_STATUS:-1}\"\n")
    # Supervisor tests own a synthetic host, including storage. Scanning real
    # worktree caches can consume the readiness deadline before cancellation
    # is exercised. Keep the real budget calculation and refusal path active.
    FileUtils.mkdir_p(File.join(@dir, "target"))
    write_command("git", <<~'SH')
      #!/bin/bash
      printf 'worktree %s\n' "$FAKE_ROOT"
    SH
    write_command("df", <<~'SH')
      #!/bin/bash
      printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
      printf 'fixture 41943040 0 %s 0%% /\n' "${FAKE_FREE_KIB:-31457280}"
    SH
    write_command("du", <<~'SH')
      #!/bin/bash
      shift # The production measurement passes -sk before literal cache paths.
      for cache_path in "$@"; do
        printf '%s\t%s\n' "${FAKE_CACHE_KIB:-0}" "$cache_path"
      done
    SH
    @env = { "PATH" => "#{@dir}:#{ENV.fetch('PATH')}", "FAKE_STATE" => @state,
             "FAKE_ROOT" => @dir, "FAKE_FREE_KIB" => nil, "FAKE_CACHE_KIB" => nil,
             NativeJob::FD_ENV => nil, NativeJob::PATH_ENV => nil }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_command(name, body)
    File.write(File.join(@dir, name), body)
    File.chmod(0o755, File.join(@dir, name))
  end

  def command(phase = "build", *child)
    [RUBY, SCRIPT, "--lock-path", @lock, phase, "--", *(child.empty? ? [RUBY, "-e", "File.write(ARGV[0], 'ran')", @marker] : child)]
  end

  def run_job(phase = "build", *child, env: {})
    Open3.capture3(@env.merge(env), *command(phase, *child))
  end

  def wait_for(path)
    # File.write creates the inode before publishing its PID/ready bytes.
    Timeout.timeout(5) { sleep 0.01 until File.size?(path) }
  end

  def assert_unlocked
    File.open(@lock, "a+") { |f| assert f.flock(File::LOCK_EX | File::LOCK_NB), "lease remained held" }
  end

  def intel_mac?
    RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
  end

  def test_intel_simulator_quarantine_refuses_launch_before_any_child
    skip "Intel macOS quarantine only" unless intel_mac?
    _, error, status = run_job("simulator", env: {
      "IOS_SKIP_BUILD" => "1", "EPUB2MP3_ALLOW_INTEL_SIMULATOR" => "1"
    })
    assert_equal 75, status.exitstatus, error
    assert_match(/quarantined/, error)
    assert_match(/physical-device verification/, error)
    refute File.exist?(@marker)
    refute File.exist?(@lock), "quarantine must reject before even acquiring a lease"
  end

  def test_intel_simulator_quarantine_cannot_be_bypassed_by_valid_inherited_lease
    skip "Intel macOS quarantine only" unless intel_mac?
    nested = command("simulator")
    _, error, status = run_job("build", *nested)
    assert_equal 75, status.exitstatus, error
    assert_match(/quarantined/, error)
    refute File.exist?(@marker)
    assert_unlocked
  end

  def test_success_failure_and_child_signal_preserve_exit_status_and_release
    [0, 17].each do |exit_code|
      _, error, status = run_job("build", RUBY, "-e", "exit #{exit_code}")
      assert_equal exit_code, status.exitstatus, error
      assert_unlocked
    end
    _, error, status = run_job("build", RUBY, "-e", "Process.kill('TERM', Process.pid); sleep 10")
    assert_equal 143, status.exitstatus, error
    assert_unlocked
  end

  def test_build_checks_real_fake_commands_before_child
    skip "Intel macOS preflight only" unless intel_mac?
    ["Booted", "Booting", "Shutting Down"].each do |state|
      File.write(@state, state)
      _, error, status = run_job("build")
      assert_equal 75, status.exitstatus, error
      refute File.exist?(@marker)
      assert_unlocked
    end
    File.write(@state, "Shutdown")
    [{ "FAKE_SIM_FAILURE" => "1" }, { "FAKE_METAL_STATUS" => "0" }, { "FAKE_METAL_STATUS" => "2" }].each do |env|
      _, error, status = run_job("build", env: env)
      assert_equal 75, status.exitstatus, error
      refute File.exist?(@marker)
    end
    _, error, status = run_job("build")
    assert status.success?, error
    assert File.exist?(@marker)
  end

  def test_build_and_simulator_contend_for_same_lease_and_recheck_state
    File.open(@lock, "a+") do |holder|
      holder.flock(File::LOCK_EX)
      %w[build simulator].each do |phase|
        _, error, status = run_job(phase)
        assert_equal 75, status.exitstatus, error
        assert_match(phase == "simulator" && intel_mac? ? /quarantined/ : /active/, error)
        refute File.exist?(@marker)
      end
      File.write(@state, "Booted")
    end
    if intel_mac?
      _, error, status = run_job("build")
      assert_equal 75, status.exitstatus, error
      refute File.exist?(@marker)
    end
    assert_unlocked
  end

  def test_storage_refusal_never_starts_child_and_releases_lease
    skip "Mac storage policy only" unless RUBY_PLATFORM.include?("darwin")
    [
      [{ "FAKE_FREE_KIB" => "1" }, /Free disk below/],
      [{ "FAKE_CACHE_KIB" => (13 * 1024 * 1024).to_s }, /caches exceed/]
    ].each do |environment, message|
      _, error, status = run_job("build", env: environment)
      assert_equal 75, status.exitstatus, error
      assert_match message, error
      refute File.exist?(@marker)
      assert_unlocked
    end
  end

  def test_nested_ruby_shell_ruby_inherits_real_lease_without_deadlock
    nested = command("build")
    shell = File.join(@dir, "nested.sh")
    File.write(shell, "#!/bin/bash\nexec \"$@\"\n")
    _, error, status = run_job("build", "/bin/bash", shell, *nested)
    assert status.success?, error
    assert_equal "ran", File.read(@marker)
    assert_unlocked
  end

  def test_inherited_environment_without_descriptor_fails_closed
    _, error, status = run_job(env: { NativeJob::FD_ENV => "9", NativeJob::PATH_ENV => @lock })
    assert_equal 75, status.exitstatus, error
    refute File.exist?(@marker)
  end

  def test_unlocked_and_wrong_file_descriptors_fail_closed
    File.open(@lock, "a+") do |handle|
      env = @env.merge(NativeJob::FD_ENV => "9", NativeJob::PATH_ENV => @lock)
      _, error, status = Open3.capture3(env, *command, 9 => handle)
      assert_equal 75, status.exitstatus, error
      assert_match(/no longer held/, error)
    end
    File.open(File.join(@dir, "other"), "a+") do |handle|
      handle.flock(File::LOCK_EX)
      env = @env.merge(NativeJob::FD_ENV => "9", NativeJob::PATH_ENV => @lock)
      _, error, status = Open3.capture3(env, *command, 9 => handle)
      assert_equal 75, status.exitstatus, error
      assert_match(/another file/, error)
    end
    refute File.exist?(@marker)
  end

  def test_single_command_string_never_invokes_a_shell
    _, error, status = run_job("build", "echo injected > #{@marker}")
    assert_equal 75, status.exitstatus, error
    refute File.exist?(@marker)
    assert_unlocked
  end

  def test_same_file_descriptor_owned_by_another_process_fails_closed
    ready = File.join(@dir, "holder-ready")
    log = File.join(@dir, "holder-log")
    File.open(log, "w") do |output|
      holder = Process.spawn(RUBY, "-e", "f=File.open(ARGV[0], 'a+'); f.flock(File::LOCK_EX); File.write(ARGV[1], 'ready'); sleep 30", @lock, ready, out: output, err: output)
      wait_for(ready)
      File.open(@lock, "a+") do |impostor|
        env = @env.merge(NativeJob::FD_ENV => "9", NativeJob::PATH_ENV => @lock)
        _, error, status = Open3.capture3(env, *command, 9 => impostor)
        assert_equal 75, status.exitstatus, error
        assert_match(/does not own/, error)
        refute File.exist?(@marker)
      end
    ensure
      if holder
        Process.kill("TERM", holder) rescue Errno::ESRCH
        Process.waitpid(holder)
      end
    end
    assert_unlocked
  end

  def test_failed_leader_cannot_leave_forked_work_running
    late = File.join(@dir, "late")
    child = "fork { sleep 0.6; File.write(ARGV[0], 'escaped') }; exit 17"
    _, error, status = run_job("build", RUBY, "-e", child, late)
    assert_equal 17, status.exitstatus, error
    sleep 0.7
    refute File.exist?(late)
    assert_unlocked
  end

  def test_failed_leader_cannot_leave_a_separate_group_running
    pid_file = File.join(@dir, "failed-leader-child")
    late = File.join(@dir, "failed-leader-late")
    program = <<~'RUBY'
      Process.spawn(RbConfig.ruby, '-e',
        "File.write(ARGV.fetch(0), Process.pid); sleep 0.6; File.write(ARGV.fetch(1), 'escaped'); sleep 30",
        ARGV.fetch(0), ARGV.fetch(1), pgroup: true, out: File::NULL, err: File::NULL)
      sleep 0.01 until File.exist?(ARGV.fetch(0))
      exit 17
    RUBY
    _, error, status = run_job("build", RUBY, "-e", program, pid_file, late)
    assert_equal 17, status.exitstatus, error
    sleep 0.7
    refute File.exist?(late), "A failed leader must stop its separate-group child before it writes"
    assert_unlocked
  ensure
    if pid_file && File.file?(pid_file)
      Process.kill("KILL", Integer(File.read(pid_file))) rescue Errno::ESRCH
    end
  end

  def test_cancel_nested_supervisor_reaches_descendant_group
    pid_file = File.join(@dir, "nested-pid")
    log = File.join(@dir, "nested-log")
    inner = command("build", RUBY, "-e", "File.write(ARGV[0], Process.pid); sleep 30", pid_file)
    File.open(log, "w") do |output|
      pid = Process.spawn(@env, *command("build", *inner), out: output, err: output)
      wait_for(pid_file)
      child = Integer(File.read(pid_file))
      Process.kill("TERM", pid)
      _, status = Timeout.timeout(6) { Process.waitpid2(pid) }
      assert_equal 143, status.exitstatus, File.read(log)
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
      assert_unlocked
    ensure
      Process.kill("KILL", pid) rescue Errno::ESRCH if pid
    end
  end

  def test_cancel_terminates_child_group_and_releases_lease
    pid_file = File.join(@dir, "pid")
    log = File.join(@dir, "log")
    File.open(log, "w") do |output|
      pid = Process.spawn(@env, *command("build", RUBY, "-e", "File.write(ARGV[0], Process.pid); sleep 30", pid_file), out: output, err: output)
      wait_for(pid_file)
      child = Integer(File.read(pid_file))
      Process.kill("TERM", pid)
      _, status = Timeout.timeout(6) { Process.waitpid2(pid) }
      assert_equal 143, status.exitstatus, File.read(log)
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
      assert_unlocked
    ensure
      Process.kill("KILL", pid) rescue Errno::ESRCH if pid
    end
  end

  def test_cancellation_stops_detached_descendants_and_preserves_an_unrelated_process
    pid_file = File.join(@dir, "detached-pid")
    unrelated = Process.spawn(RUBY, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
    program = <<~'RUBY'
      Process.spawn(RbConfig.ruby, '-e', "File.write(ARGV.fetch(0), Process.pid); sleep 30",
                    ARGV.fetch(0), pgroup: true, out: File::NULL, err: File::NULL)
      sleep 30
    RUBY
    log = File.join(@dir, "detached-log")
    File.open(log, "w") do |output|
      pid = Process.spawn(@env, *command("build", RUBY, "-e", program, pid_file), out: output, err: output)
      wait_for(pid_file)
      detached = Integer(File.read(pid_file))
      Process.kill("TERM", pid)
      _, status = Timeout.timeout(6) { Process.waitpid2(pid) }
      assert_equal 143, status.exitstatus, File.read(log)
      assert_raises(Errno::ESRCH) { Process.kill(0, detached) }
      assert_equal 1, Process.kill(0, unrelated), "cancellation must not signal another process group"
      assert_unlocked
    ensure
      Process.kill("KILL", pid) rescue Errno::ESRCH if pid
      Process.kill("KILL", detached) rescue Errno::ESRCH if detached
    end
  ensure
    if unrelated
      Process.kill("KILL", unrelated) rescue Errno::ESRCH
      Process.waitpid(unrelated) rescue Errno::ECHILD
    end
  end

  def test_a_pid_with_a_different_birth_identity_is_never_signalled
    child = Process.spawn(RUBY, "-e", "sleep 30", out: File::NULL, err: File::NULL)
    NativeJob.signal_descendants({ child => { birth: "another process lifetime" } }, "TERM")
    assert_equal 1, Process.kill(0, child)
  ensure
    if child
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.waitpid(child) rescue Errno::ECHILD
    end
  end

  def test_inspection_failure_still_stops_the_original_group_and_releases_its_lease
    pid_file = File.join(@dir, "inspection-child")
    log = File.join(@dir, "inspection-log")
    write_command("ps", <<~'SH')
      #!/bin/bash
      [[ -f "$FIXTURE_PS_FAILURE_TRIGGER" ]] && exit 23
      exec /bin/ps "$@"
    SH
    File.open(log, "w") do |output|
      environment = @env.merge("FIXTURE_PS_FAILURE_TRIGGER" => pid_file)
      pid = Process.spawn(environment, *command("build", RUBY, "-e",
                          "File.write(ARGV.fetch(0), Process.pid); sleep 30", pid_file), out: output, err: output)
      wait_for(pid_file)
      child = Integer(File.read(pid_file))
      Process.kill("TERM", pid)
      _, status = Timeout.timeout(15) { Process.waitpid2(pid) }
      assert_equal 75, status.exitstatus, File.read(log)
      assert_match(/Cannot inspect native process ownership/, File.read(log))
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
      assert_unlocked
    ensure
      Process.kill("KILL", pid) rescue Errno::ESRCH if pid
      Process.kill("KILL", child) rescue Errno::ESRCH if child
    end
  end
end
