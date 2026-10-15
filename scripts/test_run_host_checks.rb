# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "json"

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
end
