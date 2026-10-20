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
  COMPILER_TASKS = %w[rust:health rust:server migration:build-and-gate converter-ffi:android-check sidecar:build piper:build-runtime web:wasm-build].freeze
  TASKS = (%w[ios:build ios:device:build ios:simulator:test ios:simulator:run ios:simulator:resume ios:simulator:smoke:test mac:build converter-ffi:ios-packaging:test] + COMPILER_TASKS).to_h do |name|
    output, error, status = Open3.capture3("mise", "tasks", "info", name, "--json", chdir: ROOT)
    raise "Cannot read mise task #{name}: #{error}" unless status.success?
    [name, JSON.parse(output).fetch("run").join("\n")]
  end

  def setup
    @dir = Dir.mktmpdir("native-task-wiring-")
    @bin = File.join(@dir, "bin")
    @events = File.join(@dir, "events")
    @target_dir = File.join(@dir, "custom-target")
    FileUtils.mkdir_p([@bin, File.join(@dir, "scripts"), File.join(@dir, "ios/EpubToMp3"), File.join(@target_dir, "debug")])
    %w[native_job.rb native_build_preflight.rb native_build_command.rb mac_build_budget.rb].each do |file|
      FileUtils.cp(File.join(__dir__, file), File.join(@dir, "scripts", file))
    end
    FileUtils.mkdir_p(File.join(@dir, "config"))
    FileUtils.cp(File.join(ROOT, "config/mac-build-budget.json"), File.join(@dir, "config"))
    _, error, status = Open3.capture3("git", "init", "-q", @dir)
    raise "Cannot initialize isolated task fixture: #{error}" unless status.success?
    FileUtils.cp(File.join(__dir__, "dev_backend.sh"), File.join(@dir, "scripts", "dev_backend.sh"))
    wasm_build = File.join(@dir, "scripts/build_web_wasm.sh")
    File.write(wasm_build, "#!/bin/bash\nset -euo pipefail\nmise exec -- cargo build -p converter-wasm --target wasm32-unknown-unknown --release\n")
    server = File.join(@target_dir, "debug/converter-server")
    File.write(server, <<~'SH')
      #!/bin/bash
      set -euo pipefail
      "$FIXTURE_RUBY" -e 'f=File.open(ARGV[0], "a+"); exit(f.flock(File::LOCK_EX | File::LOCK_NB) ? 0 : 97)' "$FIXTURE_LOCK"
      printf 'server|%s|%s:%s|%s|%s\n' "$*" "$HOST" "$PORT" "${PIPER_BINARY:-}" "${PIPER_MODEL:-}" >> "$FIXTURE_EVENTS"
      exit "${FIXTURE_SERVER_STATUS:-0}"
    SH
    File.chmod(0o755, server)
    packaging = File.join(@dir, "scripts/test_converter_ffi_ios_packaging.sh")
    File.write(packaging, "#!/bin/bash\necho packaging >> \"$FIXTURE_EVENTS\"\n")
    File.chmod(0o755, packaging)
    %w[ios_disk_guard.sh verify_widget_embedded.sh].each do |file|
      path = File.join(@dir, "scripts", file)
      File.write(path, "#!/bin/bash\nexit 0\n")
      File.chmod(0o755, path)
    end
    shim("mise", <<~'SH')
      if [[ "$1" == exec && "$2" == -- && "$3" == ruby ]]; then
        shift 3
        script="$1"
        shift
        exec "$FIXTURE_RUBY" "$script" --lock-path "$FIXTURE_LOCK" "$@"
      fi
      if [[ "$1" == exec && "$2" == -- && "$3" == cargo ]]; then
        shift 3
        exec cargo "$@"
      fi
      exit 98
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
    shim("cargo", <<~'SH')
      "$FIXTURE_RUBY" -e 'f=File.open(ARGV[0], "a+"); exit(f.flock(File::LOCK_EX | File::LOCK_NB) ? 97 : 0)' "$FIXTURE_LOCK"
      echo "cargo $*" >> "$FIXTURE_EVENTS"
      exit "${FIXTURE_CARGO_STATUS:-0}"
    SH
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
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "MISE_PROJECT_ROOT" => @dir, "CARGO_TARGET_DIR" => @target_dir,
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

  def run_dev_backend(env = {})
    Open3.capture3(@env.merge(env), "/bin/bash", "-euo", "pipefail", File.join(@dir, "scripts/dev_backend.sh"), chdir: @dir)
  end

  def events
    File.exist?(@events) ? File.readlines(@events, chomp: true) : []
  end

  def assert_unlocked
    lock = File.open(@env.fetch("FIXTURE_LOCK"), "a+")
    assert lock.flock(File::LOCK_EX | File::LOCK_NB), "native lease is still held"
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_guarded_rust_compiler_tasks_refuse_before_cargo_on_intel
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    COMPILER_TASKS.each do |task|
      _, error, status = run_task(task, "FIXTURE_SIM_STATE" => "Booted")
      assert_equal 75, status.exitstatus, "#{task}: #{error}"
      assert_match(/Shut down all Simulators/, error, task)
      assert_empty events, "#{task} reached task body or cargo"
      assert_unlocked
    end
  end

  def test_guarded_rust_compiler_tasks_execute_cargo_under_the_lease
    COMPILER_TASKS.each do |task|
      _, error, status = run_task(
        task,
        "FIXTURE_SIM_STATE" => "Shutdown",
        "FIXTURE_CARGO_STATUS" => "23"
      )
      assert_equal 23, status.exitstatus, "#{task}: #{error}"
      assert_equal ["cargo"], events.map { |event| event.split.first }, task
      assert_unlocked
      FileUtils.rm_f(@events)
    end
  end

  def test_dev_backend_refuses_before_cargo_on_intel
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    _, error, status = run_dev_backend("FIXTURE_SIM_STATE" => "Booted")
    assert_equal 75, status.exitstatus, error
    assert_match(/Shut down all Simulators/, error)
    assert_empty events
    assert_unlocked
  end

  def test_dev_backend_build_failure_never_starts_server
    _, error, status = run_dev_backend("FIXTURE_SIM_STATE" => "Shutdown", "FIXTURE_CARGO_STATUS" => "23")
    assert_equal 23, status.exitstatus, error
    assert_equal ["cargo"], events.map { |event| event.split.first }
    assert_unlocked
  end

  def test_dev_backend_starts_server_after_guarded_build_releases_lease
    _, error, status = run_dev_backend(
      "FIXTURE_SIM_STATE" => "Shutdown",
      "FIXTURE_CARGO_STATUS" => "0",
      "BACKEND_HOST" => "127.0.0.2",
      "BACKEND_PORT" => "8123",
      "BACKEND_RELOAD" => "1"
    )
    assert status.success?, error
    assert_equal ["cargo", "server"], events.map { |event| event.split(/[ |]/).first }
    assert_equal "server|--reload|127.0.0.2:8123||", events.last
    assert_unlocked
  end

  def test_rust_server_preserves_piper_environment_and_releases_lease_before_launch
    _, error, status = run_task("rust:server", "FIXTURE_SIM_STATE" => "Shutdown", "FIXTURE_CARGO_STATUS" => "0")
    assert status.success?, error
    assert_equal ["cargo", "server"], events.map { |event| event.split(/[ |]/).first }
    assert_equal "server||127.0.0.1:8000|#{@dir}/.venv/bin/piper|#{@dir}/models/piper/en_US-lessac-medium.onnx", events.last
    assert_unlocked
  end

  def test_dev_backend_default_reload_does_not_require_nonempty_array
    _, error, status = run_dev_backend("FIXTURE_SIM_STATE" => "Shutdown", "FIXTURE_CARGO_STATUS" => "0")
    assert status.success?, error
    assert_equal ["cargo", "server"], events.map { |event| event.split(/[ |]/).first }
    assert_equal "server||127.0.0.1:8000||", events.last
  end

  def test_blocked_preflight_never_invokes_compiler_or_task_body
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    %w[ios:build ios:simulator:test].each do |task|
      _, error, status = run_task(task, "FIXTURE_SIM_STATE" => "Booted")
      assert_equal 75, status.exitstatus, error
      assert_empty events - ["generate"]
    end
  end

  def test_mac_build_preflight_precedes_generation_and_ignores_legacy_override
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    _, error, status = run_task("mac:build", "FIXTURE_SIM_STATE" => "Booted", "HEAVY_JOB_GUARD_DISABLE" => "1")
    assert_equal 75, status.exitstatus, error
    assert_match(/Shut down all Simulators/, error)
    assert_empty events
    assert_unlocked
  end

  def test_ios_device_build_preflight_precedes_generation_and_device_resolution
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    _, error, status = run_task("ios:device:build", "FIXTURE_SIM_STATE" => "Booted")
    assert_equal 75, status.exitstatus, error
    assert_match(/Shut down all Simulators/, error)
    assert_empty events
    assert_unlocked
  end

  def test_ios_packaging_preflight_precedes_clang_entrypoint
    skip "Intel macOS preflight only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    _, error, status = run_task("converter-ffi:ios-packaging:test", "FIXTURE_SIM_STATE" => "Booted")
    assert_equal 75, status.exitstatus, error
    assert_match(/Shut down all Simulators/, error)
    assert_empty events
    assert_unlocked
  end

  def test_ios_build_failure_stops_before_success_tail
    output, error, status = run_task("ios:build", "FIXTURE_BUILD_STATUS" => "17")
    assert_equal 65, status.exitstatus, error
    assert_equal ["generate", "build"], events
    assert_match(/BUILD FAILED/, output)
  end

  def quarantined?(status, error)
    return false unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    assert_equal 75, status.exitstatus, error
    assert_match(/quarantined/, error)
    assert_empty events
    true
  end

  def test_all_simulator_launch_entrypoints_refuse_before_their_task_bodies_on_intel
    skip "Intel macOS quarantine only" unless RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
    %w[ios:simulator:run ios:simulator:resume ios:simulator:smoke:test].each do |task|
      _, error, status = run_task(task)
      assert_equal 75, status.exitstatus, "#{task}: #{error}"
      assert_match(/quarantined/, error, task)
      assert_empty events, "#{task} reached its task body"
      assert_unlocked
    end
  end

  def test_test_build_failure_never_boots_or_runs_tests
    _, error, status = run_task("ios:simulator:test", "FIXTURE_BUILD_STATUS" => "17")
    return if quarantined?(status, error)
    assert_equal 17, status.exitstatus, error
    assert_equal ["generate", "build-for-testing"], events
  end

  def test_success_builds_before_boot_and_runs_without_building
    _, error, status = run_task("ios:simulator:test")
    return if quarantined?(status, error)
    assert status.success?, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus", "test-without-building"], events
  end

  def test_skip_build_only_boots_and_executes_existing_tests
    _, error, status = run_task("ios:simulator:test", "IOS_SKIP_BUILD" => "1")
    return if quarantined?(status, error)
    assert status.success?, error
    assert_equal ["generate", "boot", "bootstatus", "test-without-building"], events
  end

  def test_failed_boot_status_never_runs_test_process
    _, error, status = run_task("ios:simulator:test", "FIXTURE_BOOT_STATUS" => "21")
    return if quarantined?(status, error)
    assert_equal 21, status.exitstatus, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus"], events
  end

  def test_test_failure_preserves_status
    _, error, status = run_task("ios:simulator:test", "FIXTURE_TEST_STATUS" => "19")
    return if quarantined?(status, error)
    assert_equal 19, status.exitstatus, error
    assert_equal ["generate", "build-for-testing", "boot", "bootstatus", "test-without-building"], events
  end
end
