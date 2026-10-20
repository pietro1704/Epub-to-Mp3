# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "timeout"

# Execute the real Edit/Stop hook shells. Every native tool is a failing fixture;
# these checks never contact Apple services, compile code or boot a device.
class NativeHookSafetyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HOOKS = %w[swift_test_after_edit.sh xcode_build_smoke.sh].freeze

  def setup
    @temporary = Dir.mktmpdir("native-hook-")
    @root = File.join(@temporary, "checkout ' literal")
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p(@bin)
    @marker = File.join(@root, "native-called")
    @git_marker = File.join(@root, "git-called")
    @lease = File.join(@root, "lease")
    @environment = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "FIXTURE_ROOT" => @root,
      "FIXTURE_NATIVE" => @marker, "FIXTURE_GIT" => @git_marker,
      "FIXTURE_CHANGED" => "1", "FIXTURE_UNTRACKED" => "0",
      "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil
    }
    shim("git", <<~'SH')
      printf '%s\n' "$*" >> "$FIXTURE_GIT"
      if [[ "${FIXTURE_GIT_WAIT:-0}" == 1 ]]; then
        while true; do sleep 0.05; done
      fi
      case "$*" in
        *rev-parse*) printf '%s\n' "$FIXTURE_ROOT" ;;
        *ls-files*)
          if [[ "$FIXTURE_UNTRACKED" == 1 ]]; then printf '%s\n' 'ios/EpubToMp3/EpubToMp3UITests/New.swift'; fi ;;
        *diff*)
          if [[ "$FIXTURE_CHANGED" == 1 ]]; then printf '%s\n' 'ios/EpubToMp3/EpubToMp3/Fixture.swift'; fi ;;
        *) exit 99 ;;
      esac
    SH
    %w[mise swift xcodebuild xcrun ruby].each do |name|
      shim(name, 'printf "%s\n" "$0 $*" >> "$FIXTURE_NATIVE"; exit 97')
    end
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\nset -euo pipefail\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_hook(hook, environment = {}, file: "EpubToMp3/Fixture.swift")
    payload = JSON.generate("tool_input" => { "file_path" => File.join(@root, "ios/EpubToMp3", file) })
    Open3.capture3(@environment.merge(environment), "bash", File.join(ROOT, ".claude/hooks", hook), stdin_data: payload, chdir: @root)
  end

  def assert_notification(hook, environment = {})
    output, error, status = run_hook(hook, environment)
    assert status.success?, output + error
    assert_includes error, "native verification pending"
    assert_includes error, "automatic compilation disabled"
    refute File.exist?(@marker), "hook invoked a native tool"
  end

  def test_idle_and_booted_states_never_start_native_work
    %w[Shutdown Booted].each do |state|
      HOOKS.each { |hook| assert_notification(hook, "FIXTURE_STATE" => state) }
    end
  end

  def test_missing_guard_does_not_reenable_automatic_work
    refute File.exist?(File.join(@root, "scripts/native_job.rb"))
    HOOKS.each { |hook| assert_notification(hook) }
  end

  def test_busy_lease_does_not_start_or_wait_for_native_work
    File.open(@lease, "a+") do |lock|
      lock.flock(File::LOCK_EX)
      Timeout.timeout(3) { HOOKS.each { |hook| assert_notification(hook) } }
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
    end
  end

  def test_environment_flags_cannot_enable_compilation
    environment = { "EPUB_NATIVE_LEASE_FD" => "9", "EPUB_NATIVE_LEASE_PATH" => @lease,
                    "EPUB_NATIVE_AUTO_BUILD" => "1", "EPUB2MP3_NATIVE_AUTO_BUILD" => "1" }
    HOOKS.each { |hook| assert_notification(hook, environment) }
  end

  def test_swift_edit_notifications_include_ui_tests_and_ignore_other_files
    %w[EpubToMp3/Fixture.swift EpubToMp3Tests/Fixture.swift EpubToMp3UITests/Fixture.swift].each do |file|
      _, error, status = run_hook(HOOKS.first, {}, file: file)
      assert status.success?
      assert_includes error, "native verification pending"
    end
    output, error, status = run_hook(HOOKS.first, {}, file: "README.md")
    assert status.success?
    assert_empty output + error
    refute File.exist?(@marker)
  end

  def test_stop_reports_untracked_swift_and_is_silent_without_swift_changes
    assert_notification(HOOKS.last, "FIXTURE_CHANGED" => "0", "FIXTURE_UNTRACKED" => "1")
    output, error, status = run_hook(HOOKS.last, { "FIXTURE_CHANGED" => "0" })
    assert status.success?
    assert_empty output + error
    refute File.exist?(@marker)
  end

  def test_cancelled_edit_notification_cannot_leave_native_work
    input_read, input_write = IO.pipe
    pid = Process.spawn(@environment, "bash", File.join(ROOT, ".claude/hooks", HOOKS.first),
                        in: input_read, out: File::NULL, err: File::NULL, chdir: @root, pgroup: true)
    input_read.close
    Process.kill("TERM", -pid)
    status = Timeout.timeout(3) { Process.waitpid2(pid).last }
    assert status.signaled? || status.exitstatus == 143
    refute File.exist?(@marker)
  ensure
    input_read&.close unless input_read&.closed?
    input_write&.close unless input_write&.closed?
    Process.kill("KILL", -pid) rescue Errno::ESRCH if pid
    Process.waitpid(pid) rescue Errno::ECHILD if pid
  end

  def test_cancelled_stop_notification_cannot_leave_native_work
    pid = Process.spawn(@environment.merge("FIXTURE_GIT_WAIT" => "1"), "bash", File.join(ROOT, ".claude/hooks", HOOKS.last),
                        in: File::NULL, out: File::NULL, err: File::NULL, chdir: @root, pgroup: true)
    Timeout.timeout(3) { sleep 0.01 until File.exist?(@git_marker) }
    Process.kill("TERM", -pid)
    status = Timeout.timeout(3) { Process.waitpid2(pid).last }
    assert status.signaled? || status.exitstatus == 143
    refute File.exist?(@marker)
  ensure
    Process.kill("KILL", -pid) rescue Errno::ESRCH if pid
    Process.waitpid(pid) rescue Errno::ECHILD if pid
  end
end
