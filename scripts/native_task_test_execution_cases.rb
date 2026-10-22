# frozen_string_literal: true

# Loaded by test_native_task_wiring.rb; preserve the existing suite selectors and fixture.
class NativeTaskWiringTest
  # Run only the task function with owned Apple-tool shims. The fixture build
  # lease exercises command handling without entering any Simulator launcher.
  def run_test_function(env = {})
    function = TASKS.fetch("ios:simulator:test")[/^run_simulator_tests\(\) \{\n.*?^\}\n/m]
    refute_nil function
    arguments = File.join(@dir, "xcode-arguments.jsonl")
    shim("xcodebuild", <<~'SH')
      "$FIXTURE_RUBY" -e 'f=File.open(ARGV[0], "a+"); exit(f.flock(File::LOCK_EX | File::LOCK_NB) ? 97 : 0)' "$FIXTURE_LOCK"
      "$FIXTURE_RUBY" -rjson -e 'File.open(ARGV.shift, "a") { |f| f.puts(JSON.generate(ARGV)) }' "$FIXTURE_ARGUMENTS" "$@"
      case " $* " in
        *" build-for-testing "*) echo build-for-testing >> "$FIXTURE_EVENTS"; exit "${FIXTURE_BUILD_STATUS:-0}" ;;
        *" test-without-building "*) echo test-without-building >> "$FIXTURE_EVENTS"; exit "${FIXTURE_TEST_STATUS:-0}" ;;
        *) exit 98 ;;
      esac
    SH
    script = "DEST=\"$IOS_DEST\"; DD=\"$APPLE_DERIVED_DATA_PATH\"; UDID=\"$IOS_SIMULATOR_UDID\"\n#{function}\nrun_simulator_tests\n"
    result = Open3.capture3(@env.merge("IOS_TESTS" => "", "IOS_TEST_SHARDS" => "0", "FIXTURE_ARGUMENTS" => arguments).merge(env),
                            RbConfig.ruby, File.join(@dir, "scripts/native_job.rb"),
                            "--lock-path", @env.fetch("FIXTURE_LOCK"), "build", "--",
                            "/bin/bash", "-euo", "pipefail", "-c", script, chdir: File.join(@dir, "ios/EpubToMp3"))
    calls = File.exist?(arguments) ? File.readlines(arguments).map { |line| JSON.parse(line) } : []
    [*result, calls]
  end

  def test_system_bash_accepts_empty_optional_settings_and_filters
    _, error, status, calls = run_test_function
    assert status.success?, error
    assert_equal ["build-for-testing", "boot", "bootstatus", "test-without-building"], events
    assert_equal 2, calls.size
    calls.each { |args| refute_includes args, "" }
    refute calls.last.any? { |arg| arg.start_with?("-only-testing:") }
    assert_unlocked
  end

  def test_system_bash_handles_empty_optional_shard_groups
    tests = File.join(@dir, "ios/EpubToMp3/EpubToMp3Tests")
    FileUtils.mkdir_p([tests, File.join(@dir, "ios/EpubToMp3/EpubToMp3UITests")])
    File.write(File.join(tests, "Fixture.swift"), "final class Fixture: XCTestCase {}\n")
    _, error, status, calls = run_test_function("IOS_TEST_SHARDS" => "3")
    assert status.success?, error
    assert_equal ["build-for-testing", "boot", "bootstatus", "test-without-building"], events
    assert_equal 2, calls.size, "Empty shards must not start test processes"
    assert_includes calls.last, "-only-testing:EpubToMp3Tests/Fixture"
    assert_unlocked
  end

  def test_system_bash_preserves_populated_settings_and_filter_arguments
    _, error, status, calls = run_test_function(
      "EPUB2MP3_NATIVE_TTS_TEST" => "1", "EPUB2MP3_GUI_BOOK_ID" => "literal book with spaces",
      "IOS_TESTS" => "EpubToMp3Tests/One,EpubToMp3Tests/Two"
    )
    assert status.success?, error
    assert_equal 2, calls.size
    calls.each do |args|
      assert_includes args, "EPUB2MP3_NATIVE_TTS_TEST=1"
      assert_includes args, "EPUB2MP3_GUI_BOOK_ID=literal book with spaces"
      refute_includes args, ""
    end
    assert_includes calls.last, "-only-testing:EpubToMp3Tests/One"
    assert_includes calls.last, "-only-testing:EpubToMp3Tests/Two"
    assert_unlocked
  end

  def test_system_bash_retains_failure_and_cancellation_status_without_later_work
    { "FIXTURE_BUILD_STATUS" => [17, ["build-for-testing"]],
      "FIXTURE_BOOT_STATUS" => [21, ["build-for-testing", "boot", "bootstatus"]],
      "FIXTURE_TEST_STATUS" => [19, ["build-for-testing", "boot", "bootstatus", "test-without-building"]] }.each do |key, (code, expected)|
      FileUtils.rm_f(@events)
      _, error, status, = run_test_function(key => code.to_s)
      assert_equal code, status.exitstatus, error
      assert_equal expected, events
      assert_unlocked
    end
    FileUtils.rm_f(@events)
    _, error, status, = run_test_function("FIXTURE_BUILD_STATUS" => "143")
    assert_equal 143, status.exitstatus, error
    assert_equal ["build-for-testing"], events
    assert_unlocked
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
