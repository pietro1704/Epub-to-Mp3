#!/usr/bin/env ruby
# Exercise the real shell entrypoint with fake tools; never invoke a compiler/device.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class DeviceWorkflowEntrypointTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('device-workflow-entrypoint-')
    @scripts = File.join(@root, 'scripts')
    @tools = File.join(@root, 'fake-tools')
    @sources = File.join(@root, 'tools/DeviceWorkflow/Sources')
    @binary = File.join(@root, 'ios/EpubToMp3/.build/device-workflow/debug/device-workflow')
    @trace = File.join(@root, 'trace')
    FileUtils.mkdir_p([@scripts, @tools, @sources, File.dirname(@binary)])
    FileUtils.cp(File.join(__dir__, 'device-workflow.sh'), @scripts)
    @package = File.join(@root, 'tools/DeviceWorkflow/Package.swift')
    @source = File.join(@sources, 'main.swift')
    [@package, @source].each { |path| File.write(path, '// fixture') }
    executable(File.join(@tools, 'mise'), <<~'SH')
      #!/bin/bash
      printf 'mise' >> "$TEST_TRACE"
      printf ' <%s>' "$@" >> "$TEST_TRACE"
      printf '\n' >> "$TEST_TRACE"
      exit "${FAKE_BUILD_EXIT:-0}"
    SH
    executable(File.join(@tools, 'xcrun'), <<~'SH')
      #!/bin/bash
      echo 'unexpected direct xcrun' >> "$TEST_TRACE"
      exit 99
    SH
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def executable(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end

  def prepared_binary
    executable(@binary, <<~'SH')
      #!/bin/bash
      printf 'binary' >> "$TEST_TRACE"
      printf ' <%s>' "$@" >> "$TEST_TRACE"
      printf '\n' >> "$TEST_TRACE"
      exit "${FAKE_BINARY_EXIT:-0}"
    SH
    old = Time.now - 60
    [@package, @source].each { |path| File.utime(old, old, path) }
  end

  def run_entry(*args, env: {})
    Open3.capture3({ 'PATH' => "#{@tools}:#{ENV.fetch('PATH')}", 'TEST_TRACE' => @trace }.merge(env),
                  'bash', File.join(@scripts, 'device-workflow.sh'), *args)
  end

  def trace
    File.exist?(@trace) ? File.read(@trace) : ''
  end

  def assert_requires_prepare(*args)
    _out, err, status = run_entry(*args)
    refute status.success?
    assert_includes err, 'device-workflow.sh prepare'
    assert_equal '', trace, 'Refusal must not spawn compiler or workflow binary'
  end

  def test_missing_binary_never_bootstraps_passive_or_device_actions
    [[], ['status'], ['preflight'], ['test'], ['benchmark', '--preview']].each do |args|
      assert_requires_prepare(*args)
    end
  end

  def test_stale_source_and_manifest_never_bootstrap
    [@source, @package].each do |input|
      prepared_binary
      newer = Time.now + 60
      File.utime(newer, newer, input)
      assert_requires_prepare('preflight')
    end
  end

  def test_missing_sources_and_manifest_fail_closed
    prepared_binary
    FileUtils.rm_rf(@sources)
    assert_requires_prepare('status')
    FileUtils.mkdir_p(@sources)
    File.delete(@package)
    assert_requires_prepare('status')
  end

  def test_failed_freshness_traversal_fails_closed
    prepared_binary
    executable(File.join(@tools, 'find'), "#!/bin/bash\nexit 23\n")
    assert_requires_prepare('status')
  end

  def test_explicit_prepare_uses_guarded_serial_compiler_only
    _out, _err, status = run_entry('prepare')
    assert status.success?
    assert_includes trace, '<exec> <--> <ruby>'
    assert_includes trace, '<build> <--> <xcrun> <swift> <build>'
    assert_includes trace, '<--jobs> <1> <--product> <device-workflow>'
    refute_includes trace, 'binary'
  end

  def test_prepare_preserves_compiler_failure_without_running_binary
    prepared_binary
    _out, _err, status = run_entry('prepare', env: { 'FAKE_BUILD_EXIT' => '42' })
    assert_equal 42, status.exitstatus
    refute_includes trace, 'binary'
  end

  def test_host_tests_remain_explicit_guarded_and_preserve_failure
    _out, _err, status = run_entry('host-tests', env: { 'FAKE_BUILD_EXIT' => '43' })
    assert_equal 43, status.exitstatus
    assert_includes trace, '<build> <--> <xcrun> <swift> <test>'
    refute_includes trace, '<--product>'
  end

  def test_fresh_binary_forwards_default_status_without_compiling
    prepared_binary
    _out, _err, status = run_entry
    assert status.success?
    assert_equal "binary <status>\n", trace
  end

  def test_fresh_binary_forwards_arguments_and_exit_status
    prepared_binary
    _out, _err, status = run_entry('preflight', '--device', 'literal device', env: { 'FAKE_BINARY_EXIT' => '44' })
    assert_equal 44, status.exitstatus
    assert_equal "binary <preflight> <--device> <literal device>\n", trace
  end
end
