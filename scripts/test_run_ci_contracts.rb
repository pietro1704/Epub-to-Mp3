# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "run_ci_contracts"

class CiContractsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("CI contracts with spaces ")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def step(name, source)
    { "name" => name, "argv" => [RbConfig.ruby, "-e", source] }
  end

  def test_success_retains_plan_and_exact_report
    output = File.join(@root, "evidence")
    assert_equal 0, CiContracts.execute(@root, output, [step("fixture", "puts 'fixture passed'")])
    report = JSON.parse(File.read(File.join(output, "results/report.json")))
    assert_equal File.realpath(@root), report.fetch("cwd")
    assert_equal "fixture passed\n", File.read(report.fetch("steps").first.fetch("stdout"))
    assert File.file?(File.join(output, "plan.json"))
  end

  def test_failure_and_cancellation_stop_later_commands
    [17, 143].each do |code|
      output = File.join(@root, "failure-#{code}")
      source = code == 143 ? 'Process.kill("TERM", Process.pid); sleep 30' : "exit #{code}"
      steps = [step("fails", source), step("must not run", "File.write('unexpected', 'ran')")]
      assert_equal code, CiContracts.execute(@root, output, steps)
      refute File.exist?(File.join(@root, "unexpected"))
      assert_equal 1, JSON.parse(File.read(File.join(output, "results/report.json"))).fetch("steps").length
    end
  end

  def test_timeout_stops_later_commands
    output = File.join(@root, "timeout")
    first = step("times out", "sleep 30").merge("timeout_seconds" => 0.05)
    assert_equal 124, CiContracts.execute(@root, output, [first, step("must not run", "File.write('unexpected', 'ran')")])
    refute File.exist?(File.join(@root, "unexpected"))
  end

  def test_evidence_directory_cannot_be_reused
    output = File.join(@root, "existing")
    Dir.mkdir(output)
    File.write(File.join(output, "preserve"), "existing identity")
    assert_raises(Errno::EEXIST) { CiContracts.execute(@root, output, [step("unused", "exit 0")]) }
    assert_equal "existing identity", File.read(File.join(output, "preserve"))
  end

  def test_allowlist_contains_existing_fixture_files_and_no_build_commands
    root = File.expand_path("..", __dir__)
    paths = CiContracts::RUBY_SUITES.map { |path| "scripts/#{path}" } + CiContracts::NODE_SUITES + CiContracts::PYTHON_SUITES + CiContracts::ISOLATED_PYTHON_SUITES
    paths.each { |path| assert File.file?(File.join(root, path)), path }
    refute CiContracts.steps.any? { |step| %w[cargo swift swiftc xcodebuild simctl docker].include?(step.fetch("argv").first) }
    assert_equal paths.uniq, paths
  end

  def test_only_the_two_independent_slow_node_files_run_concurrently_and_each_file_runs_once
    node = CiContracts.steps.select { |entry| entry.fetch("argv").first == "node" }
    scheduled = node.flat_map { |entry| entry.fetch("argv").drop(1).reject { |argument| argument.start_with?("--") } }
    host_node = CiContracts::RUBY_SUITES.map { |name| HostChecks.suite_argv("scripts/#{name}") }.select { |argv| argv.first == "node" }.map(&:last)
    assert_equal (host_node + CiContracts::NODE_SUITES).sort, scheduled.sort
    assert_equal scheduled.length, scheduled.uniq.length
    grouped = node.select { |entry| entry.fetch("argv").include?("--test-concurrency=2") }
    assert_equal 1, grouped.length
    assert_equal ["node", "--test", "--test-concurrency=2", *CiContracts::CONCURRENT_NODE_SUITES], grouped.first.fetch("argv")
    assert_equal %w[.github/scripts/dependency-audit-results.test.cjs .github/scripts/pr-repair-safety.test.cjs], CiContracts::CONCURRENT_NODE_SUITES
    assert node.reject { |entry| entry == grouped.first }.all? { |entry| entry.fetch("argv").length == 3 }
  end

  def test_missing_git_lfs_fails_before_expensive_fixture_checks
    prerequisite = CiContracts.steps.first
    assert_equal ["git", "lfs", "version"], prerequisite.fetch("argv")
    fake_git = File.join(@root, "git")
    File.write(fake_git, "#!/bin/sh\nexit 127\n")
    File.chmod(0o755, fake_git)
    previous = ENV["PATH"]
    ENV["PATH"] = "#{@root}:#{previous}"
    output = File.join(@root, "missing-lfs")
    assert_equal 127, CiContracts.execute(@root, output,
      [prerequisite, step("expensive fixture", "File.write('unexpected', 'ran')")])
    refute File.exist?(File.join(@root, "unexpected"))
    report = JSON.parse(File.read(File.join(output, "results/report.json")))
    assert_equal ["Git LFS prerequisite"], report.fetch("steps").map { |entry| entry.fetch("name") }
  ensure
    ENV["PATH"] = previous if previous
  end
end
