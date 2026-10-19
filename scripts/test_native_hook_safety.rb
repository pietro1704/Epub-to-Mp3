# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "json"
require "timeout"

# Exercise real hook shells and NativeJob with an injected, platform-independent
# preflight. All compilers and mise are local fixtures; no Apple service runs.
class NativeHookSafetyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HOOKS = %w[swift_test_after_edit.sh xcode_build_smoke.sh].freeze

  def setup
    @temporary = Dir.mktmpdir("native-hook-")
    @root = File.join(@temporary, "checkout ' literal")
    Dir.mkdir(@root)
    @bin = File.join(@root, "bin")
    @lease = File.join(@root, "lease")
    @marker = File.join(@root, "compiler")
    @guard_event = File.join(@root, "guard")
    @native = File.join(@root, "ios/EpubToMp3")
    FileUtils.mkdir_p([@bin, File.join(@root, "scripts"), File.join(@native, "EpubToMp3.xcodeproj")])
    @environment = {
      "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "FIXTURE_ROOT" => @root,
      "FIXTURE_RUBY" => RbConfig.ruby, "FIXTURE_LEASE" => @lease,
      "FIXTURE_COMPILER" => @marker, "FIXTURE_GUARD" => @guard_event,
      "FIXTURE_BUILD_STATUS" => "0", "FIXTURE_STATE" => "Shutdown",
      "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil
    }
    shim("git", <<~'SH')
      case "$*" in
        *rev-parse*) printf '%s\n' "$FIXTURE_ROOT" ;;
        *diff*) printf '%s\n' 'ios/EpubToMp3/EpubToMp3/Fixture.swift' ;;
        *) exit 99 ;;
      esac
    SH
    shim("mise", <<~'SH')
      [[ "$1" == exec && "$2" == -- ]] || exit 98
      shift 2
      if [[ "$1" == ruby ]]; then
        shift
        exec "$FIXTURE_RUBY" "$@"
      fi
      exec "$@"
    SH
    %w[swift xcodebuild].each do |name|
      File.write(File.join(@bin, name), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        File.open(ENV.fetch("FIXTURE_LEASE"), "a+") do |lock|
          abort "compiler ran without lease" if lock.flock(File::LOCK_EX | File::LOCK_NB)
        end
        File.write(ENV.fetch("FIXTURE_COMPILER"), JSON.generate([ARGV, Dir.pwd, Process.pid]))
        if ENV["FIXTURE_WAIT"]
          loop { sleep 0.01 }
        end
        warn "compiler diagnostic without error prefix"
        exit Integer(ENV.fetch("FIXTURE_BUILD_STATUS"))
      RUBY
      File.chmod(0o755, File.join(@bin, name))
    end
    File.write(File.join(@root, "scripts/native_build_preflight.rb"), "# Fixture availability marker\n")
    File.write(File.join(@root, "scripts/native_job.rb"), <<~RUBY)
      require "json"
      require #{File.join(ROOT, "scripts/native_job.rb").inspect}
      module NativeBuildPreflight
        def self.check
          ENV.fetch("FIXTURE_STATE") == "Shutdown" ? nil : "Shutdown required; fixture preflight refused compilation"
        end
      end
      File.write(ENV.fetch("FIXTURE_GUARD"), JSON.generate(ARGV))
      exit NativeJob.main(["--lock-path", ENV.fetch("FIXTURE_LEASE"), *ARGV])
    RUBY
    @children = []
  end

  def teardown
    @children.each do |pid|
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Timeout.timeout(5) { Process.waitpid(pid) } rescue Errno::ECHILD
    end
    FileUtils.remove_entry(@temporary)
  end

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\nset -euo pipefail\n#{body}\n")
    File.chmod(0o755, path)
  end

  def payload
    JSON.generate("tool_input" => { "file_path" => File.join(@native, "EpubToMp3/Fixture.swift") })
  end

  def command(hook)
    ["bash", File.join(ROOT, ".claude/hooks", hook)]
  end

  def run_hook(hook, environment = {})
    FileUtils.rm_f(File.join(@root, ".reports/hooks/swift-test.stamp"))
    Open3.capture3(@environment.merge(environment), *command(hook), stdin_data: payload, chdir: @root)
  end

  def assert_unlocked
    File.open(@lease, "a+") { |lock| assert lock.flock(File::LOCK_EX | File::LOCK_NB), "lease leaked" }
  end

  def test_missing_guard_skips_without_any_compiler
    File.unlink(File.join(@root, "scripts/native_job.rb"))
    HOOKS.each do |hook|
      _, error, status = run_hook(hook)
      assert status.success?, error
      assert_includes error, "native safety guard unavailable"
      refute File.exist?(@marker)
    end
  end

  def test_booted_preflight_refuses_both_hooks_before_compiler
    HOOKS.each do |hook|
      output, error, status = run_hook(hook, "FIXTURE_STATE" => "Booted")
      assert_equal 75, status.exitstatus, output + error
      refute File.exist?(@marker)
      assert_equal "build", JSON.parse(File.read(@guard_event)).first
      assert_unlocked
    end
  end

  def test_busy_native_lease_refuses_both_hooks
    File.open(@lease, "a+") do |lock|
      lock.flock(File::LOCK_EX)
      HOOKS.each do |hook|
        _, _, status = run_hook(hook)
        assert_equal 75, status.exitstatus
        refute File.exist?(@marker)
      end
    end
  end

  def test_compiler_runs_under_lease_with_literal_root_and_one_job
    HOOKS.each do |hook|
      output, error, status = run_hook(hook)
      assert status.success?, output + error
      arguments, directory, = JSON.parse(File.read(@marker))
      assert_equal File.realpath(@native), directory
      assert_includes arguments, "1"
      assert_includes arguments, hook.start_with?("swift") ? "--jobs" : "-jobs"
      guard = JSON.parse(File.read(@guard_event))
      assert_equal ["build", "--", "mise", "exec", "--"], guard.take(5)
      assert_unlocked
      File.unlink(@marker)
    end
  end

  def test_real_compiler_failure_survives_even_without_error_colon_diagnostic
    HOOKS.each do |hook|
      output, error, status = run_hook(hook, "FIXTURE_BUILD_STATUS" => "17")
      assert_equal 17, status.exitstatus, output + error
      assert_unlocked
      assert_includes output, "FAILED" if hook.start_with?("xcode")
    end
  end

  def test_cancellation_reaches_guard_and_compiler_and_releases_lease
    HOOKS.each do |hook|
      FileUtils.rm_f(@marker)
      FileUtils.rm_f(File.join(@root, ".reports/hooks/swift-test.stamp"))
      input = File.join(@root, "input")
      File.write(input, payload)
      pid = Process.spawn(@environment.merge("FIXTURE_WAIT" => "1"), *command(hook), in: input, out: File::NULL, err: File::NULL, chdir: @root)
      @children << pid
      Timeout.timeout(5) { sleep 0.01 until File.exist?(@marker) }
      compiler = JSON.parse(File.read(@marker)).last
      Process.kill("TERM", pid)
      status = Timeout.timeout(6) { Process.waitpid2(pid).last }
      @children.delete(pid)
      assert_equal 143, status.exitstatus
      assert_raises(Errno::ESRCH) { Process.kill(0, compiler) }
      assert_unlocked
    end
  end
end
