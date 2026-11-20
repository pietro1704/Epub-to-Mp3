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
  RAILS = "ruby bin/rails test:all"
  NODE = "node --import ./browser_runtime/importmap_resolver.mjs --test --test-concurrency=2 browser_runtime/*.test.mjs"
  PLAIN = "exec -- "
  # On macOS each runner starts without the lease the suite's shell keeps.
  WITHHELD = "exec -- ruby ../../scripts/without_native_lease.rb "

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
      [[ "$*" == *" ruby bin/rails test:all" ]] && exit "${FIXTURE_RAILS_STATUS:-0}"
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
    assert_match(%r{\Aexec -- ruby \.\./\.\./scripts/native_job\.rb heavy -- sh -euc \$0 ruby bin/rails test:all && \$0 node .* mise exec -- ruby \.\./\.\./scripts/without_native_lease\.rb\z}, events[0])
    assert_equal [WITHHELD + RAILS, WITHHELD + NODE], events.drop(1),
                 "a test runner or the browser it starts must not inherit the lease"
    assert File.file?(File.join(ROOT, "scripts/without_native_lease.rb"))
  end

  def test_other_hosts_run_the_same_suite_without_the_lease
    events, status, error = run_task("Linux")
    assert status.success?, error
    assert_equal [PLAIN + RAILS, PLAIN + NODE], events
  end

  def test_a_failing_rails_suite_stops_before_node_and_keeps_its_status
    { "Darwin" => WITHHELD, "Linux" => PLAIN }.each do |system, prefix|
      events, status, = run_task(system, "FIXTURE_RAILS_STATUS" => "5")
      assert_equal 5, status.exitstatus, system
      assert_equal prefix + RAILS, events.last, system
      refute events.any? { |event| event.end_with?(NODE) }, system
    end
  end
end
