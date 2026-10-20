# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "json"
require "yaml"
require_relative "run_host_checks"

class HostChecksTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("epub-host-checks-")
    @script = File.expand_path("run_host_checks.rb", __dir__)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def invoke(first, second)
    output = File.join(@root, "evidence")
    out, err, status = Open3.capture3(RbConfig.ruby, @script, "--suite", first, "--suite", second, "--output", output)
    [out, err, status, output]
  end

  def test_aggregate_runs_selected_real_suites_in_order_and_retains_plan
    marker = File.join(@root, "marker")
    first = File.join(@root, "first.rb")
    second = File.join(@root, "second.rb")
    File.write(first, "File.write(#{marker.inspect}, 'one')")
    File.write(second, "abort 'wrong order' unless File.read(#{marker.inspect}) == 'one'; File.write(#{marker.inspect}, 'two')")
    _, err, status, output = invoke(first, second)
    assert status.success?, err
    assert_equal "two", File.read(marker)
    assert_equal 2, JSON.parse(File.read(File.join(output, "results/report.json"))).fetch("steps").length
    assert File.file?(File.join(output, "plan.json"))
  end

  def test_failed_suite_prevents_later_suite_and_preserves_exact_status
    marker = File.join(@root, "marker")
    first = File.join(@root, "first.rb")
    second = File.join(@root, "second.rb")
    File.write(first, "warn 'original'; exit 19")
    File.write(second, "File.write(#{marker.inspect}, 'bad')")
    _, _, status, output = invoke(first, second)
    assert_equal 19, status.exitstatus
    refute File.exist?(marker)
    assert_equal "original\n", File.read(File.join(output, "results/001.stderr"))
  end

  def test_node_suite_executes_in_the_same_gate_and_stops_later_ruby_on_failure
    first = File.join(@root, "first.mjs")
    second = File.join(@root, "second.rb")
    marker = File.join(@root, "later")
    File.write(first, "import test from 'node:test'; import assert from 'node:assert/strict'; test('real failure', () => assert.fail('node regression'));\n")
    File.write(second, "File.write(#{marker.inspect}, 'unexpected')")
    _, _, status, output = invoke(first, second)
    assert_equal 1, status.exitstatus
    refute File.exist?(marker)
    report = JSON.parse(File.read(File.join(output, "results/report.json")))
    assert_equal 1, report.fetch("steps").length
    assert_equal ["node", "--test", first], report.fetch("steps").first.fetch("argv")
    assert_includes File.read(File.join(output, "results/001.stdout")), "node regression"
  end

  def test_successful_node_suite_preserves_literal_path_and_continues
    first = File.join(@root, "quotes ' `literal` $(literal).mjs")
    second = File.join(@root, "second.rb")
    marker = File.join(@root, "later")
    File.write(first, "import test from 'node:test'; test('pass', () => {});\n")
    File.write(second, "File.write(#{marker.inspect}, 'verified')")
    _, err, status, = invoke(first, second)
    assert status.success?, err
    assert_equal "verified", File.read(marker)
  end

  def test_default_gate_and_ci_include_collaboration_tooling
    %w[test_agent_collaboration.mjs test_install_agent_collaboration.mjs
       test_collaboration_doctor.mjs test_revalidate_collaboration.mjs
       test_xcresult_job.rb].each { |name| assert_includes HostChecks::SUITES, name }
    workflow = YAML.load_file(File.expand_path("../.github/workflows/ci.yml", __dir__), aliases: true)
    job = workflow.fetch("jobs").fetch("production-packaging-guard")
    assert_equal "node", job.fetch("env").fetch("MISE_ENABLE_TOOLS")
    steps = job.fetch("steps")
    install = steps.index { |step| step["run"] == "mise install" }
    run = steps.index { |step| step["run"] == "mise exec -- ruby scripts/run_host_checks.rb" }
    refute_nil install
    refute_nil run
    assert_operator install, :<, run
  end
end
