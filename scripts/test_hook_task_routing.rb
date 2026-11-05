# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "mise_task_bodies"

class HookTaskRoutingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = File.realpath(Dir.mktmpdir("hook-task-routing-"))
    %w[.claude/hooks .githooks scripts bin].each { |dir| FileUtils.mkdir_p(File.join(@root, dir)) }
    @events = File.join(@root, "events")
    @env = {"PATH" => "#{@root}/bin:#{ENV.fetch('PATH')}", "HOOK_EVENTS" => @events}
    script("scripts/test_reader_change_check.sh", 'echo reader >> "$HOOK_EVENTS"; exit "${READER_STATUS:-0}"')
    script("bin/mise", 'echo "$*" >> "$HOOK_EVENTS"; exit "${MISE_STATUS:-0}"')
    script(".claude/hooks/example.sh", "exit 0")
    script(".githooks/pre-commit", "exit 0")
    script("scripts/reader-change-check.sh", "exit 0")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def script(path, body)
    full = File.join(@root, path)
    File.write(full, "#!/bin/bash\nset -euo pipefail\n#{body}\n")
    File.chmod(0o755, full)
  end

  def invoke(name, env = {})
    body = MiseTaskBodies.load(ROOT, [name]).fetch(name)
    Open3.capture3(@env.merge(env), "/bin/bash", "-euo", "pipefail", "-c", body, chdir: @root)
  end

  def test_focused_check_validates_hooks_without_starting_the_host_gate
    output, error, status = invoke("hooks:check")
    assert status.success?, "#{output}#{error}"
    assert_equal "reader\n", File.read(@events)
  end

  def test_focused_check_rejects_syntax_and_reader_failures
    script(".claude/hooks/example.sh", "if then")
    _, _, status = invoke("hooks:check")
    refute status.success?
    script(".claude/hooks/example.sh", "exit 0")
    _, _, status = invoke("hooks:check", "READER_STATUS" => "23")
    assert_equal 23, status.exitstatus
  end

  def test_full_gate_retains_both_checks_and_stops_on_first_failure
    _, error, status = invoke("hooks-test")
    assert status.success?, error
    assert_equal ["run hooks:check", "run host:workflow:test"], File.readlines(@events, chomp: true)
    File.delete(@events)
    _, _, status = invoke("hooks-test", "MISE_STATUS" => "19")
    assert_equal 19, status.exitstatus
    assert_equal ["run hooks:check"], File.readlines(@events, chomp: true)
  end
end
