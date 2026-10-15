# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

# Execute mise's actual shell bodies in an isolated fake toolchain. No compiler,
# Apple service, Python runtime, Simulator, app, or device is invoked.
class NativeTaskWiringTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  TASKS = %w[ios:build ios:simulator:test].to_h do |name|
    output, error, status = Open3.capture3("mise", "tasks", "info", name, "--json", chdir: ROOT)
    raise "Cannot read mise task #{name}: #{error}" unless status.success?
    [name, JSON.parse(output).fetch("run").join("\n")]
  end

  def setup
    @dir = Dir.mktmpdir("native-task-wiring-")
    @bin = File.join(@dir, "bin")
    @events = File.join(@dir, "events")
    FileUtils.mkdir_p([@bin, File.join(@dir, "scripts"), File.join(@dir, "ios/EpubToMp3")])
    %w[native_job.rb native_build_preflight.rb].each do |file|
      FileUtils.cp(File.join(__dir__, file), File.join(@dir, "scripts", file))
    end
    %w[ios_disk_guard.sh verify_widget_embedded.sh].each do |file|
      path = File.join(@dir, "scripts", file)
      File.write(path, "#!/bin/bash\nexit 0\n")
      File.chmod(0o755, path)
    end
    shim("mise", <<~'SH')
      [[ "$1" == exec && "$2" == -- && "$3" == ruby ]] || exit 98
      shift 3
      script="$1"
      shift
      exec "$FIXTURE_RUBY" "$script" --lock-path "$FIXTURE_LOCK" "$@"
    SH
    shim("xcrun", <<~'SH')
      [[ "$1" == simctl ]] || exit 98
      shift
      case "$1" in
        list) printf '{"devices":{"fixture":[{"state":"%s"}]}}\n' "${FIXTURE_SIM_STATE:-Shutdown}" ;;
        boot|bootstatus) echo "$1" >> "$FIXTURE_EVENTS"; [[ "$1" != bootstatus ]] || exit "${FIXTURE_BOOT_STATUS:-0}" ;;
        *) exit 98 ;;
      esac
    SH
    shim("pgrep", 'exit 1')
    shim("python3", 'exit 0')
    shim("xcodegen", 'echo generate >> "$FIXTURE_EVENTS"')
    shim("sleep", 'exit 0')
    shim("xcodebuild", <<~'SH')
      "$FIXTURE_RUBY" -e 'f=File.open(ARGV[0], "a+"); exit(f.flock(File::LOCK_EX | File::LOCK_NB) ? 97 : 0)' "$FIXTURE_LOCK"
      case " $* " in
        *" -showdestinations "*) echo 'platform:iOS Simulator,' ;;
        *" build-for-testing "*)
          echo build-for-testing >> "$FIXTURE_EVENTS"
          exit "${FIXTURE_BUILD_STATUS:-0}" ;;
        *" test-without-building "*)
          echo test-without-building >> "$FIXTURE_EVENTS"
          exit "${FIXTURE_TEST_STATUS:-0}" ;;
        *" build "*)
          echo build >> "$FIXTURE_EVENTS"
          exit "${FIXTURE_BUILD_STATUS:-0}" ;;
        *) exit 98 ;;
      esac
    SH
    @env = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "MISE_PROJECT_ROOT" => @dir,
      "FIXTURE_RUBY" => RbConfig.ruby, "FIXTURE_EVENTS" => @events,
      "FIXTURE_LOCK" => File.join(@dir, "lease"), "TMPDIR" => @dir,
      "IOS_SIMULATOR_UDID" => "00000000-0000-0000-0000-000000000001",
      "IOS_DEST" => "id=00000000-0000-0000-0000-000000000001",
      "IOS_TESTS" => "EpubToMp3Tests/Fixture", "IOS_SKIP_BUILD" => "0",
      "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\nset -euo pipefail\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_task(name, env = {})
    Open3.capture3(@env.merge(env), "/bin/bash", "-euo", "pipefail", "-c", TASKS.fetch(name), chdir: @dir)
  end

  def events
    File.exist?(@events) ? File.readlines(@events, chomp: true) : []
  end

  def test_blocked_preflight_never_invokes_compiler_or_task_body
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    %w[ios:build ios:simulator:test].each do |task|
      _, error, status = run_task(task, "FIXTURE_SIM_STATE" => "Booted")
      assert_equal 75, status.exitstatus, error
      assert_empty events - ["generate"]
    end
  end

  def test_ios_build_failure_stops_before_success_tail
    output, error, status = run_task("ios:build", "FIXTURE_BUILD_STATUS" => "17")
    assert_equal 65, status.exitstatus, error
    assert_equal ["generate", "build"], events
    assert_match(/BUILD FAILED/, output)
  end

  def test_test_build_failure_never_boots_or_runs_tests
    _, error, status = run_task("ios:simulator:test", "FIXTURE_BUILD_STATUS" => "17")
    assert_equal 17, status.exitstatus, error
    assert_equal ["generate", "build-for-testing"], events
  end

  def test_success_builds_before_boot_and_runs_without_building
    _, error, status = run_task("ios:simulator:test")
    assert status.success?, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus", "test-without-building"], events
  end

  def test_skip_build_only_boots_and_executes_existing_tests
    _, error, status = run_task("ios:simulator:test", "IOS_SKIP_BUILD" => "1")
    assert status.success?, error
    assert_equal ["generate", "boot", "bootstatus", "test-without-building"], events
  end

  def test_failed_boot_status_never_runs_test_process
    _, error, status = run_task("ios:simulator:test", "FIXTURE_BOOT_STATUS" => "21")
    assert_equal 21, status.exitstatus, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus"], events
  end

  def test_test_failure_preserves_status
    _, error, status = run_task("ios:simulator:test", "FIXTURE_TEST_STATUS" => "19")
    assert_equal 19, status.exitstatus, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus", "test-without-building"], events
  end
end
