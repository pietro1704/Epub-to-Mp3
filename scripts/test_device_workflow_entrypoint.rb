#!/usr/bin/env ruby
# Exercise the real shell entrypoint with fake tools; never invoke a compiler/device.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

class DeviceWorkflowEntrypointTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('device-workflow-entrypoint-')
    @scripts = File.join(@root, 'scripts')
    @tools = File.join(@root, 'fake-tools')
    @sources = File.join(@root, 'tools/DeviceWorkflow/Sources')
    @binary = File.join(@root, 'ios/EpubToMp3/.build/device-workflow/debug/device-workflow')
    @trace = File.join(@root, 'trace')
    FileUtils.mkdir_p([@scripts, @tools, @sources, File.dirname(@binary)])
    ['device-workflow.sh', 'device_workflow_receipt.rb'].each { |file| FileUtils.cp(File.join(__dir__, file), @scripts) }
    @package = File.join(@root, 'tools/DeviceWorkflow/Package.swift')
    @source = File.join(@sources, 'main.swift')
    [@package, @source].each { |path| File.write(path, '// fixture') }
    executable(File.join(@tools, 'mise'), <<~'SH')
      #!/bin/bash
      printf 'mise' >> "$TEST_TRACE"
      printf ' <%s>' "$@" >> "$TEST_TRACE"
      printf '\n' >> "$TEST_TRACE"
      [[ "$1" == exec && "$2" == -- && "$3" == ruby && "$4" == "$DEVICE_WORKFLOW_ROOT/scripts/native_job.rb" && "$5" == build && "$6" == -- ]] || exit 98
      shift 6
      if [[ "$1" == bash ]]; then
        [[ "$2" == -euo && "$3" == pipefail && "$4" == -s && "$5" == -- && "$6" == "$DEVICE_WORKFLOW_ROOT" && "$7" == "$DEVICE_WORKFLOW_CACHE" && "$8" == "$DEVICE_WORKFLOW_RUBY" && "$#" == 8 ]] || exit 98
      else
        [[ "$1" == xcrun && "$2" == swift && "$3" == test ]] || exit 98
      fi
      exec "$@"
    SH
    @fixture = File.join(@root, 'fixture-binary')
    executable(@fixture, "#!/bin/bash\nprintf 'binary' >> \"$TEST_TRACE\"\nprintf ' <%s>' \"$@\" >> \"$TEST_TRACE\"\nprintf '\\n' >> \"$TEST_TRACE\"\nexit \"${FAKE_BINARY_EXIT:-0}\"\n")
    executable(File.join(@tools, 'xcrun'), <<~'SH')
      #!/bin/bash
      printf 'compiler' >> "$TEST_TRACE"
      printf ' <%s>' "$@" >> "$TEST_TRACE"
      printf '\n' >> "$TEST_TRACE"
      if [[ "${FAKE_BUILD_EXIT:-0}" == 0 ]]; then
        /bin/cp "$TEST_BINARY_FIXTURE" "$DEVICE_WORKFLOW_CACHE/debug/device-workflow"
        if [[ "${FAKE_SOURCE_RACE:-0}" == 1 ]]; then
          printf 'changed during build' >> "$DEVICE_WORKFLOW_ROOT/tools/DeviceWorkflow/Sources/main.swift"
        fi
      fi
      exit "${FAKE_BUILD_EXIT:-0}"
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
    FileUtils.cp(@fixture, @binary)
    _out, err, status = run_entry('prepare')
    assert status.success?, err
    File.delete(@trace) if File.exist?(@trace)
  end

  def run_entry(*args, env: {})
    Open3.capture3({ 'PATH' => "#{@tools}:#{ENV.fetch('PATH')}", 'TEST_TRACE' => @trace, 'TEST_BINARY_FIXTURE' => @fixture, 'DEVICE_WORKFLOW_RUBY' => RbConfig.ruby }.merge(env),
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
      original = File.mtime(input)
      File.write(input, 'changed bytes')
      File.utime(original, original, input)
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

  def test_missing_receipt_and_deleted_source_fail_closed
    prepared_binary
    File.delete(File.join(File.dirname(File.dirname(@binary)), 'preparation.json'))
    assert_requires_prepare('status')
    prepared_binary
    File.delete(@source)
    assert_requires_prepare('status')
  end

  def test_changed_binary_and_added_source_fail_closed
    prepared_binary
    File.open(@binary, 'a') { |file| file.write("\n# replaced") }
    assert_requires_prepare('status')
    prepared_binary
    File.write(File.join(@sources, 'extra.swift'), '// new source')
    assert_requires_prepare('status')
  end

  def test_toolchain_selection_changes_require_prepare_without_native_probe
    prepared_binary
    ['DEVELOPER_DIR', 'TOOLCHAINS'].each do |key|
      _out, err, status = run_entry('status', env: { key => 'different-toolchain' })
      refute status.success?
      assert_includes err, 'device-workflow.sh prepare'
      assert_equal '', trace
    end
  end

  def test_optional_lockfile_and_wrapper_bytes_are_bound
    prepared_binary
    File.write(File.join(@root, 'tools/DeviceWorkflow/Package.resolved'), '{}')
    assert_requires_prepare('status')
    prepared_binary
    File.open(File.join(@scripts, 'device-workflow.sh'), 'a') { |file| file.write("\n# changed wrapper\n") }
    assert_requires_prepare('status')
  end

  def test_corrupt_receipt_cannot_authorize_binary
    prepared_binary
    File.write(File.join(File.dirname(File.dirname(@binary)), 'preparation.json'), '{invalid')
    assert_requires_prepare('preflight')
  end

  def test_system_launcher_is_refused_without_native_probe
    _out, err, status = run_entry('status', env: { 'DEVICE_WORKFLOW_RUBY' => '/usr/bin/ruby' })
    refute status.success?
    assert_includes err, 'installed Ruby executable'
    assert_equal '', trace
  end

  def test_symlink_to_system_launcher_is_refused_without_execution
    link = File.join(@tools, 'ruby-launcher')
    File.symlink('/usr/bin/ruby', link)
    _out, err, status = run_entry('status', env: { 'DEVICE_WORKFLOW_RUBY' => link })
    refute status.success?
    assert_includes err, 'installed Ruby executable'
    assert_equal '', trace
  end

  def test_source_symlink_is_not_admitted
    prepared_binary
    File.delete(@source)
    File.symlink(@package, @source)
    assert_requires_prepare('status')
  end

  def test_copied_worktree_cannot_reuse_foreign_receipt
    prepared_binary
    Dir.mktmpdir('foreign-workflow-') do |foreign|
      FileUtils.cp_r(File.join(@root, '.'), foreign)
      _out, err, status = Open3.capture3({ 'PATH' => "#{@tools}:#{ENV.fetch('PATH')}",
        'TEST_TRACE' => @trace, 'DEVICE_WORKFLOW_RUBY' => RbConfig.ruby },
        'bash', File.join(foreign, 'scripts/device-workflow.sh'), 'status')
      refute status.success?
      assert_includes err, 'device-workflow.sh prepare'
      assert_equal '', trace
    end
  end

  def test_source_change_during_build_cannot_issue_receipt
    _out, err, status = run_entry('prepare', env: { 'FAKE_SOURCE_RACE' => '1' })
    refute status.success?
    assert_includes err, 'Sources changed during preparation'
    File.delete(@trace)
    assert_requires_prepare('status')
  end

  def test_explicit_prepare_uses_guarded_serial_compiler_only
    _out, _err, status = run_entry('prepare')
    assert status.success?
    assert_includes trace, '<exec> <--> <ruby>'
    assert_includes trace, '<build> <--> <bash> <-euo> <pipefail> <-s> <-->'
    assert_includes trace, 'compiler <swift> <build>'
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
