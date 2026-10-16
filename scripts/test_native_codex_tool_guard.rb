#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "native_codex_tool_guard"

class NativeCodexToolGuardTest < Minitest::Test
  def test_known_native_execution_is_denied_without_environment_escape
    [
      "xcrun simctl boot DEVICE", "/usr/bin/xcrun simctl launch booted app.id",
      "env GITHUB_ACTIONS=true xcodebuild -scheme App build",
      "ruby scripts/native_job.rb simulator -- app",
      "mise run converter-ffi:ios-simulator", "flutter run -d macos",
      "cargo build --target aarch64-apple-ios", "open -a Simulator",
      "/Applications/Simulator.app/Contents/MacOS/Simulator",
      "bash -lc 'xcrun simctl boot DEVICE'", "env bash", "zsh -i",
      "bash -s", "xcodebuild -list -runFirstLaunch",
      "true;xcodebuild build", 'echo "$(xcrun simctl boot id)"',
      "mise run mac:run", "mise run mac:build", "mise run flutter:run",
      "mise run flutter:run-desktop", "true;mise run ios:simulator:run",
      "true;flutter run -d macos", "true;cargo build --target aarch64-apple-ios",
      'echo "$(flutter run -d macos)"',
      "xcrun simctl shutdown all && xcrun simctl boot DEVICE",
      "rg native .; xcodebuild test", "xcodebuild -version && xcodebuild build"
    ].each { |command| assert NativeCodexToolGuard.blocked?(command), command }
    assert NativeCodexToolGuard.blocked?("cat harmless.txt", tty: true)
  end

  def test_inspection_and_cleanup_remain_available
    [
      "xcrun simctl list devices -j", "xcrun simctl shutdown all",
      "xcrun simctl terminate booted app.id", "xcodebuild -version",
      "xcodebuild -project 'App With Spaces.xcodeproj' -list",
      "rg 'simctl boot' docs", "cat scripts/native_job.rb", "git diff",
      "rg 'xcodebuild|simctl' file", "echo 'xcodebuild build; simctl boot DEVICE'",
      "mise run ios:device:status", "mise run ios:device:preflight",
      %q[osascript -e 'tell application "Simulator" to quit']
    ].each { |command| refute NativeCodexToolGuard.blocked?(command), command }
  end

  def invoke(payload, common)
    output, error, status = Open3.capture3(
      RbConfig.ruby, File.expand_path("native_codex_tool_guard.rb", __dir__), common,
      stdin_data: payload
    )
    assert status.success?, error
    assert_empty error
    output.empty? ? nil : JSON.parse(output)
  end

  def test_real_git_worktrees_share_scope_without_executing_payload
    Dir.mktmpdir("native guard ") do |root|
      repository = File.join(root, "repo")
      worktree = File.join(root, "other worktree")
      unrelated = File.join(root, "unrelated")
      FileUtils.mkdir_p([repository, unrelated])
      commands = [
        ["git", "init", "-q", repository],
        ["git", "-C", repository, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture"],
        ["git", "-C", repository, "worktree", "add", "--detach", worktree],
        ["git", "init", "-q", unrelated]
      ]
      commands.each do |argv|
        _, error, status = Open3.capture3(*argv)
        assert status.success?, error
      end
      common = File.join(repository, ".git")
      marker = File.join(root, "must never run")
      command = "xcrun simctl boot DEVICE; touch #{Shellwords.escape(marker)} # SECRET"
      payload = { hook_event_name: "PreToolUse", tool_name: "Bash", cwd: worktree, tool_input: { command: command } }
      decision = invoke(JSON.generate(payload), common)
      assert_equal "deny", decision.dig("hookSpecificOutput", "permissionDecision")
      refute_includes JSON.generate(decision), "SECRET"
      refute File.exist?(marker)
      payload[:cwd] = unrelated
      assert_nil invoke(JSON.generate(payload), common)
      payload[:tool_input][:workdir] = worktree
      assert_equal "deny", invoke(JSON.generate(payload), common).dig("hookSpecificOutput", "permissionDecision")
      payload[:cwd] = worktree
      payload[:tool_input][:workdir] = unrelated
      assert_equal "deny", invoke(JSON.generate(payload), common).dig("hookSpecificOutput", "permissionDecision")
      payload[:cwd] = root
      payload[:tool_name] = "exec_command"
      payload[:tool_input] = { cmd: "git diff" }
      assert_nil invoke(JSON.generate(payload), common)
      payload[:cwd] = worktree
      payload[:tool_input] = { cmd: "xcodebuild build" }
      assert_equal "deny", invoke(JSON.generate(payload), common).dig("hookSpecificOutput", "permissionDecision")
      payload[:tool_input] = { cmd: "git diff", command: "xcodebuild build" }
      assert_equal "deny", invoke(JSON.generate(payload), common).dig("hookSpecificOutput", "permissionDecision")
    end
  end

  def test_malformed_inputs_emit_valid_secret_free_denial
    ["not JSON SECRET", "[]", JSON.generate(hook_event_name: "PreToolUse", tool_name: "Bash", cwd: "/", tool_input: {})].each do |input|
      output = invoke(input, "/missing scope")
      assert_equal "PreToolUse", output.dig("hookSpecificOutput", "hookEventName")
      assert_equal "deny", output.dig("hookSpecificOutput", "permissionDecision")
      refute_includes JSON.generate(output), "SECRET"
    end
  end
end
