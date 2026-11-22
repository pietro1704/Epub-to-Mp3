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
    write_command("df", <<~'SH')
      #!/bin/bash
      printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
      printf 'fixture 41943040 0 %s 0%% /\n' "${FAKE_FREE_KIB:-31457280}"
    SH
    @env = { "PATH" => "#{@dir}:#{ENV.fetch('PATH')}", "FAKE_FREE_KIB" => nil, NativeJob::WAIT_ENV => nil,
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

  def test_readiness_waits_for_pid_bytes_after_file_creation
    pid_file = File.join(@dir, "delayed-pid")
    File.write(pid_file, "")
    publisher = Thread.new { sleep 0.1; File.write(pid_file, Process.pid) }
    wait_for(pid_file)
    assert_equal Process.pid.to_s, File.read(pid_file)
  ensure
    publisher&.join
  end

  def assert_unlocked
    File.open(@lock, "a+") { |f| assert f.flock(File::LOCK_EX | File::LOCK_NB), "lease remained held" }
  end

  def test_simulator_phase_runs_under_the_lease_on_every_host_without_a_quarantine
    _, error, status = run_job("simulator", env: { "IOS_SKIP_BUILD" => "1" })
    assert status.success?, error
    assert_equal "ran", File.read(@marker)
    assert_unlocked
    File.delete(@marker)
    _, error, status = run_job("build", *command("simulator"))
    assert status.success?, "a simulator job nested in a build inherits the lease: #{error}"
    assert_equal "ran", File.read(@marker)
    assert_unlocked
  end

  LOCAL = { "GITHUB_ACTIONS" => nil, "RUNNER_ENVIRONMENT" => nil, "ImageOS" => nil, "CARGO_BUILD_JOBS" => nil }.freeze
  HOSTED = { "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "github-hosted", "ImageOS" => "macos15", "CARGO_BUILD_JOBS" => nil }.freeze

  def test_build_jobs_are_one_except_on_github_hosted_runners_where_they_follow_the_cpus_with_a_cap
    runner = "/Users/runner"
    assert_equal 1, NativeJob.build_jobs({}, processors: 8, home: runner)
    assert_equal 1, NativeJob.build_jobs(HOSTED.merge("RUNNER_ENVIRONMENT" => "self-hosted"), processors: 8, home: runner)
    %w[GITHUB_ACTIONS RUNNER_ENVIRONMENT ImageOS].each { |key| assert_equal 1, NativeJob.build_jobs(HOSTED.merge(key => nil), processors: 8, home: runner), key }
    assert_equal 1, NativeJob.build_jobs(HOSTED, processors: 8, home: "/Users/pips"), 'Copied variables on another account stay serial'
    assert_equal 1, NativeJob.build_jobs(HOSTED, processors: 8, home: nil)
    { 1 => 1, 3 => 3, 4 => 4, 16 => NativeJob::HOSTED_BUILD_JOBS_CAP }.each do |cpus, jobs|
      assert_equal jobs, NativeJob.build_jobs(HOSTED, processors: cpus, home: runner)
      assert_equal jobs, NativeJob.build_jobs(HOSTED, processors: cpus, home: "/home/runner")
    end
    assert_equal 1, NativeJob.build_jobs(HOSTED.merge("CARGO_BUILD_JOBS" => "1"), processors: 3, home: runner), 'A pinned 1 is honored'
    assert_equal 2, NativeJob.build_jobs(HOSTED.merge("CARGO_BUILD_JOBS" => "2"), processors: 3, home: runner)
    assert_equal 3, NativeJob.build_jobs(HOSTED.merge("CARGO_BUILD_JOBS" => "64"), processors: 3, home: runner)
    assert_equal 3, NativeJob.build_jobs(HOSTED.merge("CARGO_BUILD_JOBS" => "0"), processors: 3, home: runner)
  end

  def test_child_receives_one_job_locally_even_with_copied_hosted_variables
    program = ["-e", 'File.write(ARGV[0], [ENV["CARGO_BUILD_JOBS"], ENV["CMAKE_BUILD_PARALLEL_LEVEL"]].join(","))', @marker]
    _, error, status = run_job("build", RUBY, *program, env: LOCAL.merge("CARGO_BUILD_JOBS" => "64"))
    assert status.success?, error
    assert_equal "1,1", File.read(@marker)
    _, error, status = run_job("build", RUBY, *program, env: HOSTED.merge("CARGO_BUILD_JOBS" => "64"))
    assert status.success?, error
    # On an actual hosted runner the account home matches; anywhere else it stays 1.
    hosted = NativeJob::HOSTED_RUNNER_HOMES.include?(NativeJob.account_home)
    expected = hosted ? Etc.nprocessors.clamp(1, NativeJob::HOSTED_BUILD_JOBS_CAP).to_s : "1"
    assert_equal "#{expected},#{expected}", File.read(@marker)
  end

  def test_explicit_parallel_flags_are_never_refused
    write_command("cargo", "#!/bin/bash\necho \"$@\" > \"$FAKE_MARKER\"\n")
    write_command("xcodebuild", "#!/bin/bash\necho \"$@\" > \"$FAKE_MARKER\"\n")
    [["cargo", "build", "--jobs", "3"], ["cargo", "build", "-j2"], ["xcodebuild", "build", "-jobs", "3"],
     ["xcodebuild", "build", "-parallelizeTargets"]].each do |compiler|
      File.delete(@marker) if File.exist?(@marker)
      _, error, status = run_job("build", *compiler, env: { "FAKE_MARKER" => @marker })
      assert status.success?, "#{compiler.join(' ')}: #{error}"
      assert_equal compiler.drop(1).join(" "), File.read(@marker).strip
      assert_unlocked
    end
    refute_respond_to NativeJob, :parallelism_error
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

  def test_build_and_simulator_contend_for_the_same_lease
    File.open(@lock, "a+") do |holder|
      holder.flock(File::LOCK_EX)
      %w[build simulator].each do |phase|
        _, error, status = run_job(phase)
        assert_equal 75, status.exitstatus, error
        assert_match(/active/, error)
        refute File.exist?(@marker)
      end
    end
    assert_unlocked
  end

  def test_low_storage_is_only_an_advisory_and_the_child_runs_to_the_end
    skip "Build storage readings apply on macOS and Arch" unless RUBY_PLATFORM.include?("darwin") || File.file?("/etc/arch-release")
    _, error, status = run_job("build", env: { "FAKE_FREE_KIB" => "1" })
    assert status.success?, error
    assert_match(/advisory, not a refusal: Free disk below/, error)
    assert_equal "ran", File.read(@marker)
    assert_unlocked
    # A reading taken during the run never stops it either.
    _, error, status = run_job("build", RUBY, "-e", "sleep 1; File.write(ARGV[0], 'finished')", @marker, env: { "FAKE_FREE_KIB" => "1" })
    assert status.success?, error
    assert_equal "finished", File.read(@marker)
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
end
