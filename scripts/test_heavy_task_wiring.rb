# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "mise_task_bodies"

# Runs mise's actual `rails:web:test` body with fake tools. No Rails process,
# browser or Node test runs; only the routing through the host lease is checked.
class HeavyTaskWiringTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BODY = MiseTaskBodies.load(ROOT, %w[rails:web:test]).fetch("rails:web:test")
  RAILS = "exec -- ruby bin/rails test:all"
  NODE = "exec -- node --import ./browser_runtime/importmap_resolver.mjs --test --test-concurrency=2 browser_runtime/*.test.mjs"

  def setup
    @dir = File.realpath(Dir.mktmpdir("heavy-task-wiring-"))
    @gateway = File.join(@dir, "ruby_app/rails_gateway")
    @events = File.join(@dir, "events")
    FileUtils.mkdir_p([File.join(@dir, "bin"), File.join(@gateway, "browser_runtime")])
    # A real match makes an unquoted glob visible as an expanded argument.
    FileUtils.touch(File.join(@gateway, "browser_runtime/expanded.test.mjs"))
    shim("uname", 'echo "$FIXTURE_SYSTEM"')
    shim("mise", <<~'SH')
      printf '%s\n' "$*" >> "$FIXTURE_EVENTS"
      if [[ "$*" == "exec -- ruby ../../scripts/native_job.rb heavy -- sh -euc "* ]]; then
        [[ "$PWD" == "$FIXTURE_GATEWAY" ]] || exit 98
        shift 6
        exec "$@"
      fi
      [[ "$*" == "exec -- ruby bin/rails test:all" ]] && exit "${FIXTURE_RAILS_STATUS:-0}"
      exit 0
    SH
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def shim(name, body)
    path = File.join(@dir, "bin", name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_task(system, env = {})
    File.write(@events, "")
    environment = { "PATH" => "#{File.join(@dir, 'bin')}:#{ENV.fetch('PATH')}", "FIXTURE_EVENTS" => @events,
                    "FIXTURE_SYSTEM" => system, "FIXTURE_GATEWAY" => @gateway }.merge(env)
    _, error, status = Open3.capture3(environment, "sh", "-c", BODY, chdir: @gateway)
    [File.readlines(@events, chomp: true), status, error]
  end

  def test_macos_runs_the_suite_as_one_heavy_job_under_the_host_lease
    events, status, error = run_task("Darwin")
    assert status.success?, error
    assert_equal 3, events.length, events.inspect
    assert_match(%r{\Aexec -- ruby \.\./\.\./scripts/native_job\.rb heavy -- sh -euc mise exec -- ruby bin/rails test:all && }, events[0])
    assert_equal [RAILS, NODE], events.drop(1)
  end

  def test_other_hosts_run_the_same_suite_without_the_lease
    events, status, error = run_task("Linux")
    assert status.success?, error
    assert_equal [RAILS, NODE], events
  end

  def test_a_failing_rails_suite_stops_before_node_and_keeps_its_status
    %w[Darwin Linux].each do |system|
      events, status, = run_task(system, "FIXTURE_RAILS_STATUS" => "5")
      assert_equal 5, status.exitstatus, system
      assert_equal RAILS, events.last, system
      refute_includes events, NODE
    end
  end
end
