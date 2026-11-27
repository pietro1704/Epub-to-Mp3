# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

# Regression checks for the physical iOS device workflow.
class IosDeviceMiseTasksTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def task(name, following)
    mise = File.read(File.join(ROOT, "mise.toml"))
    start = mise.index(%([tasks."#{name}"])) or flunk("#{name} task is missing")
    finish = mise.index(%([tasks."#{following}"]), start) or flunk("#{following} task is missing")
    mise[start...finish]
  end

  def test_device_build_targets_a_connected_device_without_simulator_guard
    body = task("ios:device:build", "ios:simulator:run")

    assert_includes body, '-destination "id=$XCODE_DEVICE"'
    assert_includes body, "IOS_DEVICE_ID"
    assert_includes body, "IOS_XCODE_DEVICE_ID"
    refute_includes body, "guard_ios_simulator_resources"
  end

  # Xcode closes the lease descriptor before script phases, so a nested
  # native_job started by the bundling phase cannot succeed. The Rust library
  # must already exist when xcodebuild starts.
  def test_device_build_prepares_the_rust_library_before_xcodebuild
    script = task("ios:device:build", "ios:simulator:run")[/<<'NATIVE_JOB'\n(.*?)^NATIVE_JOB$/m, 1]
    # The heredoc sits inside a TOML basic string.
    script = script.gsub("\\\\", "\\")
    stubs = <<~SH
      xcodegen() { :; }
      xcodebuild() { echo "xcodebuild always=${CONVERTER_FFI_BUILD_ALWAYS:-unset}" >>"$CALLS"; }
      mise() { echo "mise $*" >>"$CALLS"; }
      export -f xcodegen xcodebuild mise
    SH
    { [false, "0"] => true, [true, "0"] => false, [true, "1"] => true }.each do |(present, always), builds|
      Dir.mktmpdir do |dir|
        project = File.join(dir, "ios/EpubToMp3")
        FileUtils.mkdir_p([File.join(project, "EpubToMp3.xcodeproj"), File.join(dir, "scripts"),
                           File.join(dir, "target/aarch64-apple-ios/release")])
        File.write(File.join(project, "EpubToMp3.xcodeproj/project.pbxproj"), "")
        File.write(File.join(dir, "scripts/verify_widget_embedded.sh"), "#!/bin/sh\n", perm: 0o755)
        File.write(File.join(dir, "target/aarch64-apple-ios/release/libconverter_ffi.dylib"), "") if present
        calls = File.join(dir, "calls")
        env = { "CALLS" => calls, "IOS_DEVICE_ID" => "device", "IOS_XCODE_DEVICE_ID" => "udid",
                "APPLE_DERIVED_DATA_PATH" => File.join(dir, "derived"), "TMPDIR" => dir,
                "MISE_PROJECT_ROOT" => dir, "CONVERTER_FFI_BUILD_ALWAYS" => always }
        output, status = Open3.capture2e(env, "bash", "-c", stubs + "bash -s", stdin_data: script, chdir: dir)
        assert status.success?, output
        expected = builds ? ["mise -C #{File.realpath(dir)} run converter-ffi:ios-device"] : []
        assert_equal expected + ["xcodebuild always=0"], File.readlines(calls, chomp: true),
                     "present=#{present} always=#{always}"
      end
    end
  end

  def test_vscode_exposes_device_build_and_launch_tasks
    tasks = File.read(File.join(ROOT, ".vscode/tasks.json"))

    assert_includes tasks, '"iOS: Build physical device"'
    assert_includes tasks, '"mise run ios:device:build"'
    assert_includes tasks, '"mise run ios:device:run"'
  end

  def test_device_launch_separates_app_arguments_from_devicectl_options
    assert_includes task("ios:device:run", "ios:device:build"), '"$BUNDLE_ID" -- -developmentSeedBook'
  end

  def test_sweetpad_is_pinned_to_the_nested_ios_project
    settings = File.read(File.join(ROOT, ".vscode/settings.json"))

    assert_includes settings, '"sweetpad.build.xcodeWorkspacePath": "ios/EpubToMp3/EpubToMp3.xcodeproj"'
    assert_includes settings, '"sweetpad.build.scheme": "EpubToMp3"'
    assert_includes settings, '"sweetpad.build.configuration": "Debug"'
  end
end
