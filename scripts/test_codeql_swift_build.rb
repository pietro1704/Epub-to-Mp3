# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class IosDeviceTaskEnvironmentTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def setup
    @temporary = File.realpath(Dir.mktmpdir('ios-task-environment'))
    @root = File.join(@temporary, 'project with spaces')
    @bin = File.join(@root, 'bin')
    @calls = File.join(@root, 'calls.jsonl')
    @lease = File.join(@root, 'fixture.lease')
    FileUtils.mkdir_p([@bin, File.join(@root, 'scripts')])
    FileUtils.cp(File.join(ROOT, 'scripts/apple_target_clang.sh'), File.join(@root, 'scripts'))
    File.write(File.join(@root, 'scripts/native_job.rb'), <<~'RUBY')
      abort 'Unexpected fixture lease invocation' unless ARGV.shift(2) == ['build', '--']
      File.open(ENV.fetch('FIXTURE_LEASE'), 'a+') do |file|
        abort 'Fixture lease unavailable' unless file.flock(File::LOCK_EX | File::LOCK_NB)
        exec(*ARGV, 9 => file)
      end
    RUBY
    shim('xcrun', <<~'RUBY')
      abort 'Unexpected SDK lookup' unless ARGV[0] == '--sdk' && %w[macosx iphoneos].include?(ARGV[1])
      case ARGV[2..]
      when ['--show-sdk-path'] then puts File.join(ENV.fetch('MISE_PROJECT_ROOT'), 'SDKs', "#{ARGV[1]}.sdk")
      when ['--find', 'clang'], ['--find', 'clang++'] then puts File.join(ENV.fetch('FIXTURE_BIN'), ARGV.last)
      else abort 'Unexpected SDK operation'
      end
    RUBY
    shim('mise', <<~RUBY)
      require 'json'
      abort 'Unexpected mise operation' unless ARGV.shift(2) == ['exec', '--']
      if ARGV.first == 'ruby'
        ARGV.shift
        exec #{RbConfig.ruby.inspect}, *ARGV
      elsif ARGV == ['rustup', 'which', '--toolchain', 'stable', 'rustc']
        puts File.join(ENV.fetch('FIXTURE_BIN'), 'rustc')
        exit
      end
      abort 'Unexpected compiler operation' unless ARGV.first == 'cargo'
      File.open(ENV.fetch('FIXTURE_LEASE'), 'a+') do |file|
        abort 'Build escaped fixture lease' if file.flock(File::LOCK_EX | File::LOCK_NB)
      end
      keys = %w[SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
                EPUB2MP3_APPLE_SDK EPUB2MP3_APPLE_CLANG_TARGET CC CXX CFLAGS CXXFLAGS
                CC_x86_64_apple_darwin CFLAGS_x86_64_apple_darwin
                CC_aarch64_apple_darwin CFLAGS_aarch64_apple_darwin
                CC_aarch64_apple_ios CFLAGS_aarch64_apple_ios
                RUSTC BINDGEN_EXTRA_CLANG_ARGS BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios
                CODEQL_TRACER_CONFIGURATION]
      File.open(ENV.fetch('FIXTURE_CALLS'), 'a') do |file|
        file.puts(JSON.generate({ argv: ARGV, environment: ENV.to_h.slice(*keys) }))
      end
      exit Integer(ENV.fetch('FIXTURE_HOST_STATUS', '0')) if ARGV.include?('espeak-rs-sys')
      exit Integer(ENV.fetch('FIXTURE_DEVICE_STATUS', '0'))
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def invoke(host_status: '0', device_status: '0')
    source = File.read(File.join(ROOT, 'mise.toml'))
    task = source.match(/^\[tasks\."converter-ffi:ios-device"\]\n.*?^run = '''\n(.*?)^'''/m)
    refute_nil task, 'real iOS device task must exist'
    Open3.capture3({ 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'MISE_PROJECT_ROOT' => @root,
                    'FIXTURE_BIN' => @bin, 'FIXTURE_CALLS' => @calls, 'FIXTURE_LEASE' => @lease,
                    'FIXTURE_HOST_STATUS' => host_status, 'FIXTURE_DEVICE_STATUS' => device_status, 'CLANG_WRAPPER' => nil,
                    'CC_x86_64_apple_darwin' => nil, 'CFLAGS_x86_64_apple_darwin' => nil,
                    'CC_aarch64_apple_darwin' => nil, 'CFLAGS_aarch64_apple_darwin' => nil,
                    'CODEQL_TRACER_CONFIGURATION' => 'fixture-codeql-tracing' },
                  '/bin/bash', '-euo', 'pipefail', '-c', task[1], chdir: @root)
  end

  def test_real_ios_task_sets_wrapper_before_device_environment_expansion
    output, error, status = invoke
    assert status.success?, "#{output}#{error}"
    calls = File.readlines(@calls).map { |line| JSON.parse(line) }
    assert_equal 2, calls.length
    host, device = calls
    refute_nil device, 'device build must follow host phonemizer assets'
    assert_equal %w[cargo build -p espeak-rs-sys --features compile-espeak-intonations --target-dir] +
                 [File.join(@root, 'target/espeak-data'), '--jobs', '1'], host.fetch('argv')
    host_env = host.fetch('environment')
    assert_equal File.join(@root, 'SDKs/macosx.sdk'), host_env.fetch('SDKROOT')
    assert_equal File.join(@bin, 'clang'), host_env.fetch('CC')
    refute host_env.key?('EPUB2MP3_APPLE_SDK')
    assert_equal 'fixture-codeql-tracing', host_env.fetch('CODEQL_TRACER_CONFIGURATION')
    sdk = File.join(@root, 'SDKs/iphoneos.sdk')
    assert_equal ['cargo', '--config', 'target.aarch64-apple-ios.linker="clang"', '--config',
                  "target.aarch64-apple-ios.rustflags=[\"-C\",\"link-arg=-isysroot\",\"-C\",\"link-arg=#{sdk}\"]",
                  'build', '-p', 'converter-ffi', '--release', '--features', 'piper-runtime',
                  '--target', 'aarch64-apple-ios', '--jobs', '1'], device.fetch('argv')
    environment = device.fetch('environment')
    assert_equal File.join(@root, 'scripts/apple_target_clang.sh'), environment.fetch('CC_aarch64_apple_ios')
    assert_equal '15.0', environment.fetch('IPHONEOS_DEPLOYMENT_TARGET')
    assert_equal 'iphoneos', environment.fetch('EPUB2MP3_APPLE_SDK')
    assert_equal 'arm64-apple-ios15.0', environment.fetch('EPUB2MP3_APPLE_CLANG_TARGET')
    assert_equal "-target arm64-apple-ios15.0 -isysroot #{sdk}", environment.fetch('CFLAGS_aarch64_apple_ios')
    %w[BINDGEN_EXTRA_CLANG_ARGS BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios].each do |key|
      assert_equal "--target=arm64-apple-ios15.0 --sysroot=#{sdk} -include stdio.h", environment.fetch(key)
    end
    assert_equal File.join(@bin, 'rustc'), environment.fetch('RUSTC')
    assert_equal 'fixture-codeql-tracing', environment.fetch('CODEQL_TRACER_CONFIGURATION')
  end

  def test_host_asset_failure_propagates_without_device_build
    output, error, status = invoke(host_status: '23')
    assert_equal 23, status.exitstatus, "#{output}#{error}"
    calls = File.readlines(@calls).map { |line| JSON.parse(line) }
    assert_equal 1, calls.length
    assert_includes calls.first.fetch('argv'), 'espeak-rs-sys'
    refute_includes calls.first.fetch('argv'), 'converter-ffi'
    File.open(@lease, 'a+') { |file| assert file.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_device_build_failure_propagates_after_host_assets
    output, error, status = invoke(device_status: '23')
    assert_equal 23, status.exitstatus, "#{output}#{error}"
    calls = File.readlines(@calls).map { |line| JSON.parse(line) }
    assert_equal 2, calls.length
    assert_includes calls.last.fetch('argv'), 'converter-ffi'
    File.open(@lease, 'a+') { |file| assert file.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_both_cargo_builds_keep_host_c_dependencies_on_the_macos_sdk
    output, error, status = invoke
    assert status.success?, "#{output}#{error}"
    calls = File.readlines(@calls).map { |line| JSON.parse(line) }
    assert_equal 2, calls.length
    calls.each do |call|
      environment = call.fetch('environment')
      %w[x86_64 aarch64].each do |architecture|
        assert_equal File.join(@bin, 'clang'), environment["CC_#{architecture}_apple_darwin"],
                     "#{call.fetch('argv')} must select the #{architecture} host compiler"
        assert_equal "-isysroot #{File.join(@root, 'SDKs/macosx.sdk')}",
                     environment["CFLAGS_#{architecture}_apple_darwin"],
                     "#{call.fetch('argv')} must retain the #{architecture} host SDK"
      end
    end
  end
end

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

  def invoke(destination, action: 'build-for-testing', **environment)
    Open3.capture3({ 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'TEST_CALLS' => @calls,
                    'GITHUB_ACTIONS' => nil, 'RUNNER_ARCH' => nil }.merge(environment),
                   'bash', @script, destination, 'EpubToMp3-UnitTests', '.build-codeql', action)
  end

  def test_build_for_testing_uses_any_mac_without_requiring_a_runnable_host_destination
    _output, error, status = invoke('platform=macOS')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_equal 'generic/platform=macOS', arguments[arguments.index('-destination') + 1]
    assert_includes arguments, 'ARCHS=arm64'
    assert_includes arguments, 'ONLY_ACTIVE_ARCH=YES'
    assert_equal 'build-for-testing', arguments.last
  end

  def test_explicit_destination_is_preserved_for_build_for_testing
    destination = 'platform=macOS,arch=arm64'
    _output, error, status = invoke(destination)
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_equal destination, arguments[arguments.index('-destination') + 1]
    assert_includes arguments, 'ARCHS=arm64'
  end

  def test_execution_actions_keep_the_runnable_host_destination
    %w[test test-without-building].each do |action|
      _output, error, status = invoke('platform=macOS', action: action)
      assert status.success?, error
      arguments = JSON.parse(File.read(@calls)).fetch('argv')
      assert_equal 'platform=macOS,arch=arm64', arguments[arguments.index('-destination') + 1]
      assert_includes arguments, 'ARCHS=arm64'
      assert_equal action, arguments.last
    end
  end

  def test_actions_arm64_runner_uses_native_artifacts_when_uname_disagrees
    _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => 'ARM64',
                                    'TEST_HOST_ARCH' => 'x86_64', 'TEST_FFI_ARCH' => 'arm64', 'TEST_ORT_ARCH' => 'arm64')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'generic/platform=macOS'
    assert_includes arguments, 'ARCHS=arm64'
  end

  def test_actions_x64_runner_uses_native_artifacts_when_uname_disagrees
    _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => 'X64',
                                    'TEST_HOST_ARCH' => 'arm64', 'TEST_FFI_ARCH' => 'x86_64', 'TEST_ORT_ARCH' => 'x86_64')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'generic/platform=macOS'
    assert_includes arguments, 'ARCHS=x86_64'
  end

  def test_actions_missing_or_unsupported_runner_architecture_prevents_inspection_and_build
    [nil, '', 'ARM', 'X86', 'arm64', 'unknown'].each do |arch|
      _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => arch,
                                      'TEST_LIPO_STATUS' => '9')
      assert_equal 2, status.exitstatus
      assert_includes error, 'Unsupported GitHub runner architecture'
      refute File.exist?(@calls)
    end
  end

  def test_outside_actions_uses_uname_despite_inherited_runner_architecture
    _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'false', 'RUNNER_ARCH' => 'X64')
    assert status.success?, error
    arguments = JSON.parse(File.read(@calls)).fetch('argv')
    assert_includes arguments, 'generic/platform=macOS'
    assert_includes arguments, 'ARCHS=arm64'
  end

  def test_actions_artifacts_must_match_runner_architecture
    %w[TEST_FFI_ARCH TEST_ORT_ARCH].each do |artifact|
      _output, error, status = invoke('platform=macOS', 'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => 'ARM64',
                                      artifact => 'x86_64')
      assert_equal 2, status.exitstatus
      assert_includes error, 'Architecture mismatch'
      refute File.exist?(@calls)
    end
  end

  def test_macos_build_uses_matching_host_artifacts_and_destination
    %w[arm64 x86_64].each do |arch|
      _output, error, status = invoke('platform=macOS', 'TEST_HOST_ARCH' => arch)
      assert status.success?, error
      call = JSON.parse(File.read(@calls))
      assert_equal File.join(@root, 'ios/EpubToMp3'), call.fetch('cwd')
      arguments = call.fetch('argv')
      assert_includes arguments, 'generic/platform=macOS'
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
    _output, error, status = invoke('generic/platform=iOS', 'TEST_LIPO_STATUS' => '9',
                                    'GITHUB_ACTIONS' => 'true', 'RUNNER_ARCH' => 'unknown')
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
