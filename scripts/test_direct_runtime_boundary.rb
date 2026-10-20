#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class DirectRuntimeBoundaryTest < Minitest::Test
  def setup
    @directory = File.realpath(Dir.mktmpdir('runtime boundary '))
    @root = File.join(@directory, 'project with spaces')
    @bin = File.join(@directory, 'bin')
    FileUtils.mkdir_p([File.join(@root, 'scripts'), File.join(@root, 'flutter_app'), @bin])
    @script = File.join(@root, 'scripts', 'check_direct_runtime_boundary.sh')
    FileUtils.cp(File.join(__dir__, 'check_direct_runtime_boundary.sh'), @script)
    FileUtils.ln_s('/usr/bin/dirname', File.join(@bin, 'dirname'))
    @log = File.join(@directory, 'calls.jsonl')
    @mise = File.join(@bin, 'mise')
    File.write(@mise, <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.open(ENV.fetch('BOUNDARY_CALLS'), 'a') do |file|
        file.puts(JSON.generate({ 'cwd' => Dir.pwd, 'argv' => ARGV }))
      end
      exit Integer(ENV.fetch(ARGV.include?('flutter') ? 'FLUTTER_EXIT' : 'WEB_EXIT', '0'))
    RUBY
    FileUtils.chmod(0o755, @mise)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(*arguments, **environment)
    Open3.capture3({ 'PATH' => @bin, 'BOUNDARY_CALLS' => @log }.merge(environment),
                   '/bin/bash', @script, *arguments, chdir: @directory)
  end

  def calls
    return [] unless File.exist?(@log)

    File.readlines(@log).map { |line| JSON.parse(line) }
  end

  def assert_blocked(status, output, code)
    assert_equal code, status.exitstatus
    refute_includes output, 'RESULT PASS'
  end

  def test_web_selection_preserves_literal_arguments_and_root
    output, error, status = invoke('web')
    assert status.success?, error
    assert_equal [{ 'cwd' => @root, 'argv' => [
      'exec', '--', 'npm', '--prefix', 'web', 'run', 'test', '--',
      'src/services/EmbeddedConverter.test.ts', 'src/services/BrowserConversionClient.test.ts',
      'src/test/App.integration.test.tsx', 'src/test/useConversionFlow.test.ts'
    ] }], calls
    assert_includes output, 'RESULT PASS: web'
  end

  def test_flutter_selection_uses_its_project_without_web
    output, error, status = invoke('flutter')
    assert status.success?, error
    assert_equal [{ 'cwd' => File.join(@root, 'flutter_app'), 'argv' => [
      'exec', '--', 'flutter', 'test', '--no-pub',
      'test/local_conversion_job_test.dart', 'test/jobs_list_screen_test.dart',
      'test/convert_screen_test.dart', 'test/rust_playback_conversion_test.dart',
      'test/desktop_conversion_worker_test.dart'
    ] }], calls
    assert_includes output, 'RESULT PASS: flutter'
  end

  def test_default_requires_both_contract_suites_in_order
    output, error, status = invoke
    assert status.success?, error
    assert_equal [@root, File.join(@root, 'flutter_app')], calls.map { |call| call['cwd'] }
    assert_equal 1, output.scan('RESULT PASS: all').length
  end

  def test_web_failure_stops_before_flutter
    output, _error, status = invoke('all', 'WEB_EXIT' => '23')
    assert_blocked status, output, 23
    assert_equal 1, calls.length
    assert_includes calls.first['argv'], 'npm'
  end

  def test_flutter_failure_propagates_after_web_success
    output, _error, status = invoke('all', 'FLUTTER_EXIT' => '31')
    assert_blocked status, output, 31
    assert_equal 2, calls.length
  end

  def test_missing_mise_cannot_report_capability_success
    FileUtils.rm(@mise)
    output, error, status = invoke('web')
    assert_blocked status, output, 127
    assert_includes error, 'mise is required'
    assert_empty calls
  end

  def test_missing_flutter_project_is_not_skipped
    FileUtils.remove_entry(File.join(@root, 'flutter_app'))
    output, _error, status = invoke('flutter')
    refute status.success?
    refute_includes output, 'RESULT PASS'
    assert_empty calls
  end

  def test_invalid_or_extra_selection_never_starts_tools
    [['unknown'], ['web', 'flutter']].each do |arguments|
      output, error, status = invoke(*arguments)
      assert_blocked status, output, 64
      assert_includes error, 'Usage:'
      assert_empty calls
    end
  end
end
