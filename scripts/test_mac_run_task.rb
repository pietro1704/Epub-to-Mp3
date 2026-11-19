# frozen_string_literal: true

require "minitest/autorun"

# Regression checks for fast native macOS rebuild decisions.
class MacRunTaskTest < Minitest::Test
  MISE = File.expand_path("../mise.toml", __dir__)

  def test_mac_run_replaces_the_previous_debug_instance
    mise = File.read(MISE)
    start = mise.index('[tasks."mac:run"]') or flunk("mac:run task is missing")
    finish = mise.index('[tasks."ios:build"]', start) or flunk("ios:build task is missing")
    task = mise[start...finish]

    assert_includes task, 'APP_EXECUTABLE="$APP_PATH/Contents/MacOS/EpubToMp3"'
    assert_includes task, 'pkill -TERM -f "$APP_EXECUTABLE"'
    assert_includes task, 'open "$APP_PATH"'
    refute_includes task, 'open -n "$APP_PATH"'
  end
end
