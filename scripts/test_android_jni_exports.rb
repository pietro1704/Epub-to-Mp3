# frozen_string_literal: true
require 'minitest/autorun'
require 'yaml'
require_relative 'android_jni_exports'

class AndroidJniExportsTest < Minitest::Test
  JOB_LOG = 'Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeJobLog'

  def nm_output(symbols = AndroidJniExports::REQUIRED)
    symbols.map { |symbol| "0000000000012340 T #{symbol}\n" }.join
  end

  def test_complete_source_and_apk_export_lists_pass
    assert_includes AndroidJniExports::REQUIRED, JOB_LOG
    assert AndroidJniExports.verify!(nm_output, label: 'Built library')
    assert AndroidJniExports.verify!(nm_output, label: 'APK JNI library')
  end

  def test_each_missing_export_fails_before_packaging_or_apk_acceptance
    AndroidJniExports::REQUIRED.each do |symbol|
      error = assert_raises(RuntimeError) { AndroidJniExports.verify!(nm_output(AndroidJniExports::REQUIRED - [symbol])) }
      assert_includes error.message, symbol
    end
  end

  def test_wrong_class_suffix_or_undefined_import_cannot_supply_job_log
    base = nm_output(AndroidJniExports::REQUIRED - [JOB_LOG])
    ["0000000000012340 T #{JOB_LOG}Extra\n", "0000000000012340 T Prefix#{JOB_LOG}\n",
     "                 U #{JOB_LOG}\n", "#{JOB_LOG}\n"].each do |replacement|
      assert_raises(RuntimeError) { AndroidJniExports.verify!(base + replacement) }
    end
  end

  def test_abi_audit_runs_where_android_artifact_is_actually_built
    root = File.expand_path('..', __dir__)
    ffi = YAML.load_file(File.join(root, '.github/workflows/converter-ffi.yml'))
    host = ffi.fetch('jobs').fetch('host-validation').fetch('steps').map { |step| step.fetch('run', '') }.join("\n")
    refute_match(/jniLibs|\bnm\b/, host)
    faber = YAML.load_file(File.join(root, '.github/workflows/faber-integration.yml'))
    steps = faber.fetch('jobs').fetch('android-package').fetch('steps')
    build_index = steps.index { |step| step.fetch('run', '').include?('mise run flutter:build-apk-debug') }
    audit_index = steps.index { |step| step.fetch('run', '').include?('package_converter_ffi_android.rb --audit --apk') }
    refute_nil build_index
    refute_nil audit_index
    assert_operator build_index, :<, audit_index
    audit = steps[audit_index].fetch('run')
    assert_match(/flutter build apk.*--target-platform android-arm64/, audit)
    assert_match(/package_converter_ffi_android\.rb --audit --apk.*app-debug\.apk/, audit)
  end
end
