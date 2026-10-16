# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "timeout"
require "json"
require_relative "xcresult_job"

class XCResultJobTest < Minitest::Test
  SCRIPT = File.expand_path("xcresult_job.rb", __dir__)
  RUBY = RbConfig.ruby

  def setup
    @directory = Dir.mktmpdir("xcresult-job-")
    @bundle = File.join(@directory, "one.xcresult")
    @other = File.join(@directory, "two.xcresult")
    [@bundle, @other].each { |path| Dir.mkdir(path) }
    @environment = { "PATH" => "#{@directory}:#{ENV.fetch('PATH')}", "XCRESULT_LOCK_TIMEOUT_SECONDS" => "3" }
    @children = []
    File.write(File.join(@directory, "xcrun"), <<~RUBY)
      #!#{RUBY}
      require "json"
      File.write(ENV.fetch("EVENT"), JSON.generate(ARGV))
      if ENV["SIGNAL"]
        Process.kill(ENV.fetch("SIGNAL"), Process.pid)
        sleep 30
      end
      if ENV["IGNORE_SIGNAL"]
        Signal.trap("TERM", "IGNORE")
        fork do
          Signal.trap("TERM", "IGNORE")
          loop { File.write(ENV.fetch("HEARTBEAT"), "alive"); sleep 0.01 }
        end
      end
      if ENV["RELEASE"]
        sleep 0.01 until File.exist?(ENV.fetch("RELEASE"))
      end
      puts "tool output"
      warn "tool diagnostic"
      exit Integer(ENV.fetch("EXIT_CODE", "0"))
    RUBY
    File.chmod(0o755, File.join(@directory, "xcrun"))
  end

  def teardown
    @children.each do |pid|
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    [@bundle, @other].each { |path| File.unlink(XCResultJob.lock_path(File.realpath(path))) rescue Errno::ENOENT }
    FileUtils.remove_entry(@directory)
  end

  def command(bundle = @bundle, *extra)
    [RUBY, SCRIPT, bundle, "--", "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle, *extra]
  end

  def run_job(bundle = @bundle, environment = {}, *extra)
    Open3.capture3(@environment.merge("EVENT" => File.join(@directory, "event")).merge(environment), *command(bundle, *extra))
  end

  def start_job(event:, bundle: @bundle, **environment)
    pid = Process.spawn(@environment.merge("EVENT" => event).merge(environment.transform_keys(&:to_s)), *command(bundle), out: File::NULL, err: "#{event}.stderr")
    @children << pid
    pid
  end

  def wait_for(path)
    Timeout.timeout(5) { sleep 0.01 until File.exist?(path) }
  end

  def reap(pid)
    status = Timeout.timeout(5) { Process.waitpid2(pid).last }
    @children.delete(pid)
    status
  end

  def test_same_bundle_excludes_waiter_and_times_out_without_invoking_tool
    first = File.join(@directory, "first")
    release = File.join(@directory, "release")
    pid = start_job(event: first, RELEASE: release)
    wait_for(first)
    event = File.join(@directory, "waiter")
    _, error, status = run_job(@bundle, "EVENT" => event, "XCRESULT_LOCK_TIMEOUT_SECONDS" => "0.15")
    assert_equal 75, status.exitstatus, error
    assert_match(/timed out/, error)
    refute File.exist?(event)
    File.write(release, "release")
    assert reap(pid).success?
    assert run_job.last.success?, "lease must be available after completion"
  end

  def test_symlink_alias_waits_for_same_bundle_then_runs
    first = File.join(@directory, "first")
    second = File.join(@directory, "second")
    release = File.join(@directory, "release")
    alias_path = File.join(@directory, "alias.xcresult")
    File.symlink(@bundle, alias_path)
    assert_equal XCResultJob.lock_path(File.realpath(@bundle)), XCResultJob.lock_path(File.realpath(alias_path))
    owner = start_job(event: first, RELEASE: release)
    wait_for(first)
    waiter = start_job(event: second, bundle: alias_path)
    # A separate contender reaches its timeout while the alias remains queued.
    assert_equal 75, run_job(@bundle, "XCRESULT_LOCK_TIMEOUT_SECONDS" => "0.15").last.exitstatus
    refute File.exist?(second)
    File.write(release, "release")
    assert reap(owner).success?
    assert reap(waiter).success?
    assert File.exist?(second)
  end

  def test_independent_bundle_runs_while_first_is_locked
    first = File.join(@directory, "first")
    release = File.join(@directory, "release")
    owner = start_job(event: first, RELEASE: release)
    wait_for(first)
    assert run_job(@other, "XCRESULT_LOCK_TIMEOUT_SECONDS" => "0.15").last.success?
    assert Process.kill(0, owner), "first operation must remain active"
    File.write(release, "release")
    assert reap(owner).success?
  end

  def test_retargeting_alias_while_waiting_cannot_redirect_the_guarded_operation
    first = File.join(@directory, "first")
    second = File.join(@directory, "second")
    release = File.join(@directory, "release")
    alias_path = File.join(@directory, "alias.xcresult")
    File.symlink(@bundle, alias_path)
    owner = start_job(event: first, RELEASE: release)
    wait_for(first)
    waiter = start_job(event: second, bundle: alias_path)
    Timeout.timeout(5) do
      sleep 0.01 until File.exist?("#{second}.stderr") && File.read("#{second}.stderr").include?("waiting for bundle lease")
    end
    File.unlink(alias_path)
    File.symlink(@other, alias_path)
    File.write(release, "release")
    assert reap(owner).success?
    assert reap(waiter).success?
    arguments = JSON.parse(File.read(second))
    assert_equal File.realpath(@bundle), arguments[arguments.index("--path") + 1]
  end

  def test_real_exit_status_output_and_literal_arguments_are_preserved
    injection = "$(touch #{@directory}/injected); `false`"
    stdout, stderr, status = run_job(@bundle, { "EXIT_CODE" => "23" }, injection)
    assert_equal 23, status.exitstatus
    assert_equal "tool output\n", stdout
    assert_equal "tool diagnostic\n", stderr
    assert_equal injection, JSON.parse(File.read(File.join(@directory, "event"))).last
    refute File.exist?(File.join(@directory, "injected"))
    assert run_job.last.success?
  end

  def test_cancellation_kills_process_group_before_releasing_lease
    event = File.join(@directory, "signal-event")
    heartbeat = File.join(@directory, "heartbeat")
    pid = start_job(event: event, RELEASE: File.join(@directory, "never"), IGNORE_SIGNAL: "1", HEARTBEAT: heartbeat)
    wait_for(heartbeat)
    Process.kill("TERM", pid)
    assert_equal 143, reap(pid).exitstatus, File.read("#{event}.stderr")
    modified_at = File.mtime(heartbeat)
    sleep 0.1
    assert_equal modified_at, File.mtime(heartbeat), "descendant continued writing after lease release"
    assert run_job.last.success?
  end

  def test_interrupt_cancellation_and_tool_signal_preserve_signal_status
    event = File.join(@directory, "interrupt")
    release = File.join(@directory, "never")
    pid = start_job(event: event, RELEASE: release)
    wait_for(event)
    Process.kill("INT", pid)
    assert_equal 130, reap(pid).exitstatus, File.read("#{event}.stderr")
    assert_equal 143, run_job(@bundle, "SIGNAL" => "TERM").last.exitstatus
    assert run_job.last.success?
  end

  def test_abrupt_supervisor_death_keeps_tool_lease_until_tool_exits
    event = File.join(@directory, "abrupt")
    release = File.join(@directory, "release")
    pid = start_job(event: event, RELEASE: release)
    wait_for(event)
    Process.kill("KILL", pid)
    assert_equal 9, reap(pid).termsig
    assert_equal 75, run_job(@bundle, "XCRESULT_LOCK_TIMEOUT_SECONDS" => "0.15").last.exitstatus
    File.write(release, "release")
    assert run_job.last.success?
  ensure
    File.write(release, "release") if release
  end

  def test_cancellation_while_waiting_does_not_release_owners_lease
    event = File.join(@directory, "owner")
    release = File.join(@directory, "release")
    owner = start_job(event: event, RELEASE: release)
    wait_for(event)
    waiter_event = File.join(@directory, "waiter")
    waiter = start_job(event: waiter_event)
    Timeout.timeout(5) do
      sleep 0.01 until File.exist?("#{waiter_event}.stderr") && File.read("#{waiter_event}.stderr").include?("waiting for bundle lease")
    end
    Process.kill("TERM", waiter)
    assert_equal 143, reap(waiter).exitstatus, File.read("#{waiter_event}.stderr")
    assert_equal 75, run_job(@bundle, "XCRESULT_LOCK_TIMEOUT_SECONDS" => "0.1").last.exitstatus
    File.write(release, "release")
    assert reap(owner).success?
  end

  def test_rejects_missing_or_different_bundle_path_and_unbounded_timeout
    event = File.join(@directory, "event")
    [["xcrun", "xcresulttool", "get"], ["xcrun", "xcresulttool", "get", "--path", @other],
     ["xcrun", "xcresulttool", "get", "--path", @bundle, "--path=#{@other}"],
     ["sh", "-c", "touch #{event}"]].each do |arguments|
      _, _, status = Open3.capture3(@environment.merge("EVENT" => event), RUBY, SCRIPT, @bundle, "--", *arguments)
      assert_equal 2, status.exitstatus
      refute File.exist?(event)
    end
    ["NaN", "Infinity", "0", "61", "invalid"].each do |value|
      assert_equal 2, run_job(@bundle, "XCRESULT_LOCK_TIMEOUT_SECONDS" => value).last.exitstatus
      refute File.exist?(event)
    end
  end

  def test_equal_path_option_accepts_canonical_alias
    alias_path = File.join(@directory, "alias.xcresult")
    File.symlink(@bundle, alias_path)
    environment = @environment.merge("EVENT" => File.join(@directory, "event"))
    _, error, status = Open3.capture3(environment, RUBY, SCRIPT, alias_path, "--", "xcrun", "xcresulttool", "get", "--path=#{@bundle}")
    assert status.success?, error
  end
end
