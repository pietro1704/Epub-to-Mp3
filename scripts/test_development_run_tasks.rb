# frozen_string_literal: true

require "minitest/autorun"

# Regression checks for local Debug run tasks.
class DevelopmentRunTasksTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @mise = File.read(File.join(ROOT, "mise.toml"))
  end

  def test_run_tasks_use_debug_development_paths
    assert_includes @mise, '[tasks."mac:run"]'
    assert_includes @mise, "mise run mac:build:dev"
    assert_includes @mise, '[tasks."ios:run"]'
    assert_includes @mise, 'TARGET="${IOS_TARGET:-device}"'
    assert_includes @mise, 'IOS_DEVICE_ID="$DEVICE" mise run ios:device:build'
    assert_includes @mise, "mise run ios:build"
    assert_includes @mise, '[tasks."flutter:run"]'
    assert_includes @mise, "select_android_target.rb"
    assert_includes @mise, 'flutter run -d "$DEVICE"'
  end

  # A legacy simulator may run an installed build without being buildable.
  def test_simulator_resume_task_launches_only_an_installed_app
    start = @mise.index('[tasks."ios:simulator:resume"]') or flunk("ios:simulator:resume task is missing")
    finish = @mise.index('[tasks."ios:simulator:test"]', start) or flunk("ios:simulator:test task is missing")
    task = @mise[start...finish]

    assert_includes task, "native_job.rb\" simulator"
    assert_includes task, "simctl bootstatus"
    assert_includes task, "simctl get_app_container"
    assert_includes task, "simctl launch"
    refute_includes task, "simctl install"
    refute_includes task, "mise run ios:build"
    refute_includes task, "xcodebuild"
    refute_includes task, "python"
  end

  def test_vscode_exposes_debug_run_tasks
    tasks = File.read(File.join(ROOT, ".vscode/tasks.json"))

    assert_includes tasks, '"mise run mac:run"'
    assert_includes tasks, '"mise run ios:run"'
    assert_includes tasks, '"mise run ios:device:build"'
    assert_includes tasks, '"mise run ios:device:run"'
    assert_includes tasks, '"mise run ios:build"'
    # Simulator execution is quarantined; Android work remains paused.
    refute_includes tasks, '"IOS_TARGET=simulator mise run ios:run"'
    refute_includes tasks, '"mise run flutter:run"'
  end
end
