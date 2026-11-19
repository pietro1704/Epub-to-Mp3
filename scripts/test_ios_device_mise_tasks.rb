# frozen_string_literal: true

require "minitest/autorun"

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
