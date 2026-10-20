# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "open3"
require "rbconfig"
require "fileutils"

class RunStepsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("epub-run-steps-")
    @script = File.expand_path("run_steps.rb", __dir__)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_plan(steps)
    plan = File.join(@root, "plan.json")
    File.write(plan, JSON.generate("cwd" => @root, "steps" => steps))
    out, err, status = Open3.capture3(RbConfig.ruby, @script, plan, File.join(@root, "logs"))
    [out, err, status]
  end

  def ruby_step(code, **options)
    { "name" => "fixture", "argv" => [RbConfig.ruby, "-e", code] }.merge(options.transform_keys(&:to_s))
  end

  def test_first_failure_preserves_status_and_prevents_later_command
    _, _, status = run_plan([ruby_step("warn 'original failure'; exit 23"), ruby_step("File.write('later', 'bad')")])
    assert_equal 23, status.exitstatus
    refute File.exist?(File.join(@root, "later"))
    report = JSON.parse(File.read(File.join(@root, "logs", "report.json")))
    assert_equal 23, report.fetch("exit_code")
    assert_equal 1, report.fetch("steps").length
    assert_equal "original failure\n", File.read(File.join(@root, "logs", "001.stderr"))
  end

  def test_literal_arguments_and_full_logs_survive_bounded_preview
    literal = "$(touch injected); `touch injected`; *"
    first = { "argv" => [RbConfig.ruby, "-e", "puts ARGV.fetch(0); puts 'x' * 100_000", literal] }
    out, err, status = run_plan([first, ruby_step("File.write('later', 'ok')")])
    assert status.success?, err
    assert_equal "ok", File.read(File.join(@root, "later"))
    refute File.exist?(File.join(@root, "injected"))
    assert File.read(File.join(@root, "logs", "001.stdout")).start_with?(literal)
    assert_operator out.bytesize, :<, 5_000
    assert_operator File.size(File.join(@root, "logs", "001.stdout")), :>, 100_000
  end

  def test_spawn_failure_is_preserved_and_stops
    _, _, status = run_plan([{ "argv" => [File.join(@root, "missing-program")] }, ruby_step("File.write('later', 'bad')")])
    assert_equal 127, status.exitstatus
    refute File.exist?(File.join(@root, "later"))
    assert_equal 127, JSON.parse(File.read(File.join(@root, "logs", "report.json"))).fetch("exit_code")
  end

  def test_single_argv_string_is_a_literal_executable_not_shell_code
    _, _, status = run_plan([{ "argv" => ["echo injected > marker"] }])
    assert_equal 127, status.exitstatus
    refute File.exist?(File.join(@root, "marker"))
  end

  def test_failed_step_terminates_descendants_before_they_continue
    code = "File.write('group', Process.pid.to_s); fork { sleep 0.5; File.write('orphan-marker', 'bad') }; sleep 0.05; exit 23"
    _, _, status = run_plan([ruby_step(code)])
    assert_equal 23, status.exitstatus
    sleep 0.6
    refute File.exist?(File.join(@root, "orphan-marker"))
  ensure
    group_file = File.join(@root, "group")
    Process.kill("KILL", -Integer(File.read(group_file))) rescue Errno::ESRCH if File.file?(group_file)
  end

  def test_signal_and_timeout_do_not_run_next_step
    _, _, status = run_plan([ruby_step("Process.kill('TERM', Process.pid); sleep 5"), ruby_step("File.write('later', 'bad')")])
    assert_equal 143, status.exitstatus
    refute File.exist?(File.join(@root, "later"))
    FileUtils.remove_entry(File.join(@root, "logs"))
    _, _, status = run_plan([ruby_step("sleep 10", timeout_seconds: 0.05), ruby_step("File.write('later', 'bad')")])
    assert_equal 124, status.exitstatus
    refute File.exist?(File.join(@root, "later"))
  end

  def test_entire_plan_is_validated_before_running_and_existing_logs_are_preserved
    _, _, status = run_plan([ruby_step("File.write('later', 'bad')"), { "argv" => "not argv" }])
    assert_equal 2, status.exitstatus
    refute File.exist?(File.join(@root, "later"))
    Dir.mkdir(File.join(@root, "logs"))
    File.write(File.join(@root, "logs", "retained"), "evidence")
    _, _, status = run_plan([ruby_step("File.write('later', 'bad')")])
    assert_equal 2, status.exitstatus
    assert_equal "evidence", File.read(File.join(@root, "logs", "retained"))
    refute File.exist?(File.join(@root, "later"))
  end

  def test_cancellation_terminates_child_and_keeps_evidence
    plan = File.join(@root, "plan.json")
    File.write(plan, JSON.generate("cwd" => @root, "steps" => [ruby_step("File.write('ready', Process.pid.to_s); sleep 20"), ruby_step("File.write('later', 'bad')")]))
    output = File.join(@root, "parent.log")
    pid = Process.spawn(RbConfig.ruby, @script, plan, File.join(@root, "logs"), out: output, err: output)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(File.join(@root, "ready"))
      raise "fixture did not become ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    child = Integer(File.read(File.join(@root, "ready")))
    Process.kill("TERM", pid)
    _, status = Process.waitpid2(pid)
    pid = nil
    assert_equal 143, status.exitstatus
    assert_raises(Errno::ESRCH) { Process.kill(0, child) }
    refute File.exist?(File.join(@root, "later"))
    assert_equal 143, JSON.parse(File.read(File.join(@root, "logs", "report.json"))).fetch("exit_code")
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end
end
