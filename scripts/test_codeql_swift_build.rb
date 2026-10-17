# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class CodeqlSwiftBuildTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir('codeql build '))
    @bin = File.join(@root, 'bin')
    FileUtils.mkdir_p([@bin, File.join(@root, 'scripts'), File.join(@root, 'ios/EpubToMp3')])
    @script = File.join(@root, 'scripts/codeql_swift_build.sh')
    FileUtils.cp(File.join(__dir__, 'codeql_swift_build.sh'), @script)
    @calls = File.join(@root, 'calls.json')
    shim('uname', "puts ENV.fetch('TEST_HOST_ARCH', 'arm64')")
    shim('xcrun', <<~'RUBY')
      exit Integer(ENV.fetch('TEST_LIPO_STATUS', '0')) unless ENV.fetch('TEST_LIPO_STATUS', '0') == '0'
      arch = ENV.fetch('TEST_HOST_ARCH', 'arm64')
      arch = ENV.fetch(ARGV.last.include?('onnxruntime') ? 'TEST_ORT_ARCH' : 'TEST_FFI_ARCH', arch)
      puts arch
    RUBY
    shim('xcodebuild', <<~'RUBY')
      require 'json'
      File.write(ENV.fetch('TEST_CALLS'), JSON.generate({ argv: ARGV, cwd: Dir.pwd }))
      Process.kill('TERM', Process.pid) if ENV['TEST_BUILD_SIGNAL'] == 'TERM'
      exit Integer(ENV.fetch('TEST_BUILD_STATUS', '0'))
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def invoke(destination, **environment)
    Open3.capture3({ 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'TEST_CALLS' => @calls,
                    'GITHUB_ACTIONS' => nil, 'RUNNER_ARCH' => nil }.merge(environment),
                   'bash', @script, destination, 'EpubToMp3-UnitTests', '.build-codeql', 'build-for-testing')
  end

  def test_actions_arm64_runner_uses_native_artifacts_when_uname_disagrees
    _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => 'ARM64',
                                    'TEST_HOST_ARCH' => 'x86_64', 'TEST_FFI_ARCH' => 'arm64', 'TEST_ORT_ARCH' => 'arm64')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'platform=macOS,arch=arm64'
    assert_includes arguments, 'ARCHS=arm64'
  end

  def test_macos_build_uses_matching_host_artifacts_and_destination
    %w[arm64 x86_64].each do |arch|
      _output, error, status = invoke('platform=macOS', 'TEST_HOST_ARCH' => arch)
      assert status.success?, error
      call = JSON.parse(File.read(@calls))
      assert_equal File.join(@root, 'ios/EpubToMp3'), call.fetch('cwd')
      arguments = call.fetch('argv')
      assert_includes arguments, "platform=macOS,arch=#{arch}"
      assert_includes arguments, "ARCHS=#{arch}"
      assert_includes arguments, 'ONLY_ACTIVE_ARCH=YES'
      assert_includes arguments, 'EpubToMp3-UnitTests'
      assert_includes arguments, '.build-codeql'
      assert_equal 'build-for-testing', arguments.last
    end
  end

  def test_generic_macos_preserves_destination_with_explicit_host_architecture
    _output, error, status = invoke('generic/platform=macOS')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'generic/platform=macOS'
    assert_includes arguments, 'ARCHS=arm64'
  end

  def test_ios_does_not_require_macos_artifacts_or_override_architecture
    _output, error, status = invoke('generic/platform=iOS', 'TEST_LIPO_STATUS' => '9')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'generic/platform=iOS'
    refute arguments.any? { |argument| argument.start_with?('ARCHS=') }
  end

  def test_mismatched_runtime_prevents_build
    _output, error, status = invoke('platform=macOS', 'TEST_ORT_ARCH' => 'x86_64')
    assert_equal 2, status.exitstatus
    assert_includes error, 'Architecture mismatch'
    refute File.exist?(@calls)
  end

  def test_artifact_inspection_failure_prevents_build
    _output, _error, status = invoke('platform=macOS', 'TEST_LIPO_STATUS' => '9')
    assert_equal 9, status.exitstatus
    refute File.exist?(@calls)
  end

  def test_mismatched_ffi_prevents_build
    _output, error, status = invoke('platform=macOS', 'TEST_FFI_ARCH' => 'x86_64')
    assert_equal 2, status.exitstatus
    assert_includes error, 'Architecture mismatch'
    refute File.exist?(@calls)
  end

  def test_build_failure_keeps_original_status
    _output, _error, status = invoke('platform=macOS', 'TEST_BUILD_STATUS' => '65')
    assert_equal 65, status.exitstatus
  end

  def test_build_cancellation_keeps_original_signal
    _output, _error, status = invoke('platform=macOS', 'TEST_BUILD_SIGNAL' => 'TERM')
    assert status.signaled?
    assert_equal 15, status.termsig
  end
end
