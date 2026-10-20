#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

class AndroidInferenceRunnerTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('android runner ')
    @root = File.join(@directory, 'project with spaces')
    @bin = File.join(@directory, 'bin')
    FileUtils.mkdir_p([File.join(@root, 'scripts'), File.join(@root, 'flutter_app'), @bin])
    @script = File.join(@root, 'scripts', 'verify_android_piper_inference.sh')
    FileUtils.cp(File.join(__dir__, 'verify_android_piper_inference.sh'), @script)
    @calls = File.join(@directory, 'calls.json')
    @adb_calls = File.join(@directory, 'adb-calls.jsonl')
    File.write(File.join(@bin, 'adb'), <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.open(ENV.fetch('TEST_ANDROID_ADB_CALLS'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
      properties = {
        'ro.build.version.sdk' => '35',
        'ro.product.cpu.abilist' => ENV.fetch('TEST_ANDROID_ABIS', 'x86_64,arm64-v8a'),
        'ro.dalvik.vm.native.bridge' => ENV.fetch('TEST_ANDROID_BRIDGE', 'libndk_translation.so'),
        'ro.dalvik.vm.isa.arm64' => 'x86_64',
        'ro.product.cpu.abi' => 'x86_64'
      }
      puts properties.fetch(ARGV.last)
    RUBY
    File.write(File.join(@bin, 'mise'), <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      File.write(ENV.fetch('TEST_ANDROID_CALLS'), JSON.generate({cwd: Dir.pwd, argv: ARGV}))
      puts ENV.fetch('TEST_ANDROID_MARKER', "ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none\\nANDROID_FABER_ABI_TRANSLATION: model=pt_BR-faber-medium")
      exit Integer(ENV.fetch('TEST_ANDROID_EXIT', '0'))
    RUBY
    FileUtils.chmod(0o755, Dir.glob(File.join(@bin, '*')))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(mode: nil, **environment)
    # The emulator action invokes each input line through sh -c, not Bash.
    command = ['bash', @script]
    command << mode unless mode.nil?
    Open3.capture3({ 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'TEST_ANDROID_CALLS' => @calls,
                    'TEST_ANDROID_ADB_CALLS' => @adb_calls }.merge(environment),
                   '/bin/sh', '-c', command.shelljoin, chdir: @directory)
  end

  def test_action_shell_preserves_bash_state_and_the_flutter_project
    output, error, status = invoke
    assert status.success?, error
    assert_includes output, 'ANDROID_ARM64_ABI_TRANSLATION: api=35'
    call = JSON.parse(File.read(@calls))
    assert_equal File.join(@root, 'flutter_app'), call.fetch('cwd')
    assert_equal %w[exec -- flutter drive], call.fetch('argv').first(4)
    assert_includes call.fetch('argv'), '--use-application-binary=build/app/outputs/flutter-apk/app-debug.apk'
    assert_includes call.fetch('argv'), '--target=integration_test/android_piper_inference_test.dart'
    assert File.exist?(File.join(@root, '.reports/tts-preferences/android-inference.log'))
  end

  def test_flutter_failure_propagates_through_tee_even_with_a_success_marker
    _output, _error, status = invoke('TEST_ANDROID_EXIT' => '23')
    assert_equal 23, status.exitstatus
  end

  def test_missing_success_marker_cannot_report_success
    _output, _error, status = invoke('TEST_ANDROID_MARKER' => 'No inference result')
    refute status.success?
  end

  def test_identity_mode_requires_no_faber_marker_and_uses_the_same_target
    output, error, status = invoke(mode: 'identity',
                                  'TEST_ANDROID_MARKER' => 'ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none')
    assert status.success?, error
    assert_includes output, 'ANDROID_JNI_JOB_IDENTITY:'
    refute_includes output, 'ANDROID_FABER_ABI_TRANSLATION:'
    assert_includes JSON.parse(File.read(@calls)).fetch('argv'), '--target=integration_test/android_piper_inference_test.dart'
  end

  def test_full_mode_requires_identity_even_when_faber_passes
    _output, _error, status = invoke(mode: 'full',
                                   'TEST_ANDROID_MARKER' => 'ANDROID_FABER_ABI_TRANSLATION: model=pt_BR-faber-medium')
    refute status.success?
  end

  def test_full_mode_requires_faber_even_when_identity_passes
    _output, _error, status = invoke(mode: 'full',
                                   'TEST_ANDROID_MARKER' => 'ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none')
    refute status.success?
  end

  def test_identity_mode_rejects_faber_without_identity
    _output, _error, status = invoke(mode: 'identity',
                                   'TEST_ANDROID_MARKER' => 'ANDROID_FABER_ABI_TRANSLATION: model=pt_BR-faber-medium')
    refute status.success?
  end

  def test_identity_mode_preserves_flutter_failure_despite_identity_marker
    _output, _error, status = invoke(mode: 'identity', 'TEST_ANDROID_EXIT' => '23')
    assert_equal 23, status.exitstatus
  end

  def test_unknown_mode_stops_before_adb_or_flutter
    ['arbitrary-target', ''].each do |mode|
      _output, error, status = invoke(mode: mode)
      assert_equal 64, status.exitstatus
      assert_includes error, 'Unknown Android verification mode.'
      refute File.exist?(@adb_calls)
      refute File.exist?(@calls)
    end
  end

  def test_unsupported_abi_stops_before_flutter
    _output, error, status = invoke('TEST_ANDROID_ABIS' => 'x86_64')
    refute status.success?
    assert_includes error, 'ARM64 ABI is unavailable'
    refute File.exist?(@calls)
  end

  def test_wrong_translation_bridge_stops_before_flutter
    _output, _error, status = invoke('TEST_ANDROID_BRIDGE' => 'unexpected.so')
    refute status.success?
    refute File.exist?(@calls)
  end
end
