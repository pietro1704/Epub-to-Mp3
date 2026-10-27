# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require_relative "mac_build_budget"

class MacBuildBudgetTest < Minitest::Test
  def test_read_only_check_retains_budget_refusal_status
    with_stub(:check, nil) { assert_equal 0, MacBuildBudget.main(["check"]) }
    with_stub(:check, "Fixture: cache budget exceeded") do
      _, error = capture_io { assert_equal 75, MacBuildBudget.main(["check"]) }
      assert_match(/Fixture: cache budget exceeded/, error)
    end
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir("mac-build-budget-"))
    @limits = { "version" => 1, "minimum_free_gib" => 20, "maximum_cache_gib" => 12,
                "check_interval_seconds" => 1 }
  end

  def test_compatibility_wrapper_only_checks_and_preserves_cache_bytes_on_success_and_refusal
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    cache = File.join(@dir, ".build-old")
    FileUtils.mkdir_p(cache)
    artifact = File.join(cache, "artifact")
    File.write(artifact, "retained cache bytes")
    File.utime(Time.now - 864_000, Time.now - 864_000, cache)
    trace = File.join(@dir, "trace")
    fake_mise = File.join(bin, "mise")
    File.write(fake_mise, <<~'SH')
      #!/bin/bash
      printf '%s\n' "$@" > "$GUARD_TEST_TRACE"
      exit "$GUARD_TEST_STATUS"
    SH
    File.chmod(0o755, fake_mise)
    [0, 75].each do |expected|
      _, error, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "GUARD_TEST_TRACE" => trace, "GUARD_TEST_STATUS" => expected.to_s,
        "IOS_DISK_GUARD_IOS_BUILD_DIR" => @dir, "IOS_DISK_GUARD_MAX_TOTAL_MB" => "0" },
        "bash", File.join(__dir__, "ios_disk_guard.sh"), chdir: @dir)
      assert_equal expected, status.exitstatus, error
      assert_equal ["-C", File.expand_path("..", __dir__), "exec", "--", "ruby",
                    File.join(__dir__, "mac_build_budget.rb"), "check"], File.readlines(trace, chomp: true)
      assert_equal "retained cache bytes", File.binread(artifact)
    end
  end

  def with_stub(name, value)
    original = MacBuildBudget.method(name)
    MacBuildBudget.define_singleton_method(name) { |*| value }
    yield
  ensure
    MacBuildBudget.define_singleton_method(name, original)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def with_du_failure(error, output: nil, before_return: nil)
    original = Open3.method(:capture3)
    _, _, failed = original.call(RbConfig.ruby, "-e", "exit 1")
    Open3.define_singleton_method(:capture3) do |*argv|
      result = original.call(*argv)
      next result unless argv.first == "du"
      before_return&.call
      [output || result.first, error, failed]
    end
    with_stub(:worktrees, [@dir]) do
      with_stub(:xcode_caches, []) { yield }
    end
  ensure
    Open3.define_singleton_method(:capture3, original) if original
  end

  def test_removed_compiler_child_keeps_complete_storage_measurement
    cache = File.join(@dir, "target")
    FileUtils.mkdir_p(File.join(cache, "deps"))
    File.write(File.join(cache, "artifact"), "x" * 4096)
    removed = File.join(cache, "deps", "rustc-removed")
    with_du_failure("du: #{removed}: No such file or directory\n") do
      snapshot = MacBuildBudget.metrics
      assert_equal [cache], snapshot.fetch(:paths)
      assert_operator snapshot.fetch(:cache_bytes), :>=, 4096
      # This regression isolates vanished compiler files from real host capacity.
      assert_nil MacBuildBudget.evaluate(@limits, **snapshot.merge(free_bytes: 30 * 1024**3))
    end
  end

  def test_incomplete_du_summary_still_blocks
    cache = File.join(@dir, "target")
    FileUtils.mkdir_p(cache)
    with_du_failure("du: #{cache}/removed: No such file or directory\n", output: "") do
      assert_raises(RuntimeError) { MacBuildBudget.metrics }
    end
  end

  def test_missing_root_existing_child_and_other_du_errors_still_block
    cache = File.join(@dir, "target")
    FileUtils.mkdir_p(cache)
    existing = File.join(cache, "existing")
    File.write(existing, "preserve")
    ["du: #{cache}: No such file or directory\n",
     "du: #{existing}: No such file or directory\n",
     "du: #{cache}/private: Permission denied\n",
     "du: /outside/removed: No such file or directory\n"].each do |error|
      with_du_failure(error) { assert_raises(RuntimeError) { MacBuildBudget.metrics } }
    end
    assert_equal "preserve", File.read(existing)
  end

  def test_replaced_cache_identity_still_blocks
    cache = File.join(@dir, "target")
    FileUtils.mkdir_p(cache)
    replace = lambda do
      File.rename(cache, File.join(@dir, "old-target"))
      Dir.mkdir(cache)
    end
    with_du_failure("du: #{cache}/removed: No such file or directory\n", before_return: replace) do
      assert_raises(RuntimeError) { MacBuildBudget.metrics }
    end
  end

  def test_boundary_and_over_budget_refusal
    assert_nil MacBuildBudget.evaluate(@limits, free_bytes: 20 * MacBuildBudget::GIB, cache_bytes: 12 * MacBuildBudget::GIB)
    assert_match(/Free disk/, MacBuildBudget.evaluate(@limits, free_bytes: 20 * MacBuildBudget::GIB - 1, cache_bytes: 0))
    assert_match(/caches exceed/, MacBuildBudget.evaluate(@limits, free_bytes: 30 * MacBuildBudget::GIB, cache_bytes: 12 * MacBuildBudget::GIB + 1))
    assert_nil MacBuildBudget.check(host: "x86_64-linux")
  end

  def test_new_xcode_index_is_counted_before_workspace_metadata_exists
    cache = File.join(@dir, "fresh-index")
    Dir.mkdir(cache)
    File.write(File.join(cache, "index"), "x" * 4096)
    with_stub(:worktrees, [@dir]) do
      with_stub(:xcode_caches, [cache]) do
        assert_empty MacBuildBudget.legacy_caches
        snapshot = MacBuildBudget.metrics
        assert_includes snapshot.fetch(:paths), cache
        assert_operator snapshot.fetch(:cache_bytes), :>, 0
      end
    end
  end

  def test_active_lease_prevents_cleanup
    cache = File.join(@dir, "old-cache")
    Dir.mkdir(cache)
    path = File.join(@dir, "lease")
    File.open(path, "a+") do |lease|
      lease.flock(File::LOCK_EX)
      with_stub(:legacy_caches, [cache]) do
        assert_raises(RuntimeError) { MacBuildBudget.prune(lock: path) }
      end
      assert File.directory?(cache)
    end
  end

  def test_compiler_without_lease_still_prevents_cleanup
    cache = File.join(@dir, "old-cache")
    Dir.mkdir(cache)
    with_stub(:capture, "/toolchain/bin/rustc\n") do
      with_stub(:legacy_caches, [cache]) do
        assert_raises(RuntimeError) { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
      end
    end
    assert File.directory?(cache)
  end

  def test_cleanup_preserves_running_app
    cache = File.join(@dir, "old-cache")
    Dir.mkdir(cache)
    with_stub(:capture, "#{cache}/App.app/Contents/MacOS/App\n") do
      with_stub(:legacy_caches, [cache]) do
        assert_raises(RuntimeError) { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
      end
    end
    assert File.directory?(cache)
  end

  def test_cleanup_does_not_follow_links_or_touch_models
    models = File.join(@dir, "models")
    cache = File.join(@dir, "old-cache")
    FileUtils.mkdir_p([models, cache])
    sentinel = File.join(models, "voice.onnx")
    File.write(sentinel, "preserve")
    File.symlink(models, File.join(cache, "external-models"))
    with_stub(:capture, "") do
      with_stub(:legacy_caches, [cache]) { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
    end
    refute File.exist?(cache)
    assert_equal "preserve", File.read(sentinel)
  end

  def fixture
    skip "Native launcher storage enforcement is macOS-specific" unless RUBY_PLATFORM.include?("darwin")
    scripts = File.join(@dir, "scripts")
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p([scripts, bin, File.join(@dir, "config"), File.join(@dir, "target"),
                      File.join(@dir, ".build")])
    %w[native_job.rb mac_build_budget.rb].each { |name| FileUtils.cp(File.join(__dir__, name), scripts) }
    File.write(File.join(scripts, "native_build_preflight.rb"), "module NativeBuildPreflight; def self.check = nil; end\n")
    File.write(File.join(@dir, "config/mac-build-budget.json"), JSON.generate(@limits))
    @free = File.join(@dir, "free-kib")
    @marker = File.join(@dir, "child")
    File.write(@free, (30 * 1024**2).to_s)
    {
      "git" => 'printf "worktree %s\n\n" "$BUDGET_FIXTURE_ROOT"',
      "df" => 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 999999999 0 %s 0%% /\n" "$(cat "$BUDGET_FREE_STATE")"',
      "du" => 'shift; for cache do printf "%s\t%s\n" "${BUDGET_CACHE_KIB:-0}" "$cache"; done',
      "plutil" => 'printf "unrelated-project\n"'
    }.each do |name, body|
      path = File.join(bin, name)
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
    end
    @env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "BUDGET_FIXTURE_ROOT" => @dir,
             "BUDGET_FREE_STATE" => @free, "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil }
    @command = [RbConfig.ruby, File.join(scripts, "native_job.rb"), "--lock-path", File.join(@dir, "lease"),
                "build", "--", RbConfig.ruby, "-e"]
  end

  def test_low_disk_blocks_before_child_and_ignores_environment_bypass
    fixture
    File.write(@free, "0")
    _, error, status = Open3.capture3(@env.merge("DISK_GUARD_THRESHOLD_GB" => "0", "EPUB_SKIP_BUDGET" => "1"),
                                     *@command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert_equal 75, status.exitstatus, error
    assert_match(/Free disk below/, error)
    refute File.exist?(@marker)
  end

  def test_cache_limit_blocks_before_child
    fixture
    _, error, status = Open3.capture3(@env.merge("BUDGET_CACHE_KIB" => (13 * 1024**2).to_s),
                                     *@command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert_equal 75, status.exitstatus, error
    assert_match(/caches exceed/, error)
    refute File.exist?(@marker)
  end

  def test_invalid_configuration_blocks_before_child
    fixture
    File.write(File.join(@dir, "config/mac-build-budget.json"), "{}")
    _, error, status = Open3.capture3(@env, *@command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert_equal 75, status.exitstatus, error
    assert_match(/inspection failed/, error)
    refute File.exist?(@marker)
  end

  def test_budget_allows_child_and_limits_compiler_jobs
    fixture
    _, error, status = Open3.capture3(@env.merge("CARGO_BUILD_JOBS" => "64"), *@command,
                                     'File.write(ARGV.fetch(0), [ENV.fetch("CARGO_BUILD_JOBS"), ENV.fetch("CMAKE_BUILD_PARALLEL_LEVEL")].join(","))', @marker)
    assert status.success?, error
    assert_equal "1,1", File.read(@marker)
  end

  def test_monitor_terminates_its_child_when_disk_floor_is_crossed
    fixture
    program = 'File.write(ARGV.fetch(0), Process.pid.to_s); File.write(ARGV.fetch(1), "0"); sleep 30'
    _, error, status = Timeout.timeout(8) { Open3.capture3(@env, *@command, program, @marker, @free) }
    assert_equal 75, status.exitstatus, error
    assert_match(/Free disk below/, error)
    pid = Integer(File.read(@marker))
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_monitor_stops_a_descendant_in_a_separate_process_group
    fixture
    program = <<~'RUBY'
      child = Process.spawn(RbConfig.ruby, '-e',
        "trap('TERM') {}; File.write(ARGV.fetch(0), Process.pid); sleep 30",
        ARGV.fetch(0), pgroup: true, out: File::NULL, err: File::NULL)
      sleep 0.01 until File.exist?(ARGV.fetch(0))
      File.write(ARGV.fetch(1), '0')
      sleep 30
    RUBY
    _, error, status = Timeout.timeout(15) { Open3.capture3(@env, *@command, program, @marker, @free) }
    assert_equal 75, status.exitstatus, error
    assert_match(/Free disk below/, error)
    descendant = Integer(File.read(@marker))
    Timeout.timeout(2) do
      loop do
        Process.kill(0, descendant)
        sleep 0.01
      rescue Errno::ESRCH
        break
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, descendant) }
    File.open(File.join(@dir, 'lease'), 'a+') do |lease|
      assert lease.flock(File::LOCK_EX | File::LOCK_NB), 'guard must release its lease after cleanup'
    end
  ensure
    if @marker && File.file?(@marker)
      Process.kill('KILL', Integer(File.read(@marker))) rescue Errno::ESRCH
    end
  end

  def test_explicit_parallel_compiler_request_is_refused_before_launch
    fixture
    compiler = File.join(@dir, "bin", "xcodebuild")
    File.write(compiler, "#!/bin/sh\nprintf ran > \"$BUDGET_MARKER\"\n")
    File.chmod(0o755, compiler)
    _, error, status = Open3.capture3(@env.merge("BUDGET_MARKER" => @marker),
                                     *@command.take(6), compiler, "-jobs", "4", "build")
    assert_equal 75, status.exitstatus, error
    assert_match(/exactly one job/, error)
    refute File.exist?(@marker)
    require_relative "native_job"
    %w[-j8 --jobs=8 --jobs=-1].each do |option|
      assert_match(/exactly one job/, NativeJob.parallelism_error(["cargo", "build", option]))
    end
    assert_match(/exactly one job/, NativeJob.parallelism_error(["cmake", "--build", ".", "--parallel", "8"]))
    assert_nil NativeJob.parallelism_error(["cargo", "build", "--jobs", "1"])
    assert_nil NativeJob.parallelism_error(["xcodebuild", "-showdestinations", "-json", "-jobs", "1"])
  end

  def test_device_and_variant_build_caches_are_counted_without_being_pruned
    caches = %w[.build-device ios/EpubToMp3/.build-device ios/EpubToMp3/.build-release].map do |relative|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "artifact"), "preserve" * 1024)
      path
    end
    with_stub(:worktrees, [@dir]) do
      with_stub(:xcode_caches, []) do
        assert_equal caches.sort, MacBuildBudget.metrics.fetch(:paths).sort
        with_stub(:capture, "") { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
        caches.each { |path| assert File.file?(File.join(path, "artifact")) }
      end
    end
  end

  def task_body(name)
    root = File.expand_path("..", __dir__)
    output, error, status = Open3.capture3("mise", "tasks", "info", name, "--json", chdir: root)
    assert status.success?, error
    JSON.parse(output).fetch("run").join("\n")
  end

  def test_apple_build_tasks_route_through_the_serial_guard
    %w[mac:build ios:build ios:device:build converter-ffi:build].each do |name|
      body = task_body(name)
      assert_match(/(?:native_job\.rb["']?\s+build\s+--|native_build_command\.rb["']?\s+--)/, body, name)
      assert_match(/(?:-jobs|--jobs)(?:["']\s*,\s*["']|\s+)1/, body, name)
      refute_match(/-parallelizeTargets/, body, name)
      _, error, status = Open3.capture3("/bin/bash", "-n", stdin_data: body)
      assert status.success?, error
    end
  end

  def test_actual_ios_build_task_uses_storage_guard_with_fake_compilers
    fixture
    body = task_body("ios:build")
    FileUtils.mkdir_p(File.join(@dir, "ios/EpubToMp3"))
    %w[ios_disk_guard.sh verify_widget_embedded.sh].each do |name|
      path = File.join(@dir, "scripts", name)
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, path)
    end
    commands = {
      "mise" => 'shift 3; script="$1"; shift; exec "$BUDGET_RUBY" "$script" --lock-path "$BUDGET_FIXTURE_ROOT/lease" "$@"',
      "python3" => 'exit 0',
      "xcodegen" => 'exit 0',
      "xcodebuild" => 'case " $* " in *" -showdestinations "*) printf "platform:iOS Simulator,\\n";; *) printf ran > "$BUDGET_MARKER"; exit "${BUDGET_COMPILER_STATUS:-0}";; esac'
    }
    commands.each do |name, command|
      path = File.join(@dir, "bin", name)
      File.write(path, "#!/bin/sh\n#{command}\n")
      File.chmod(0o755, path)
    end
    environment = @env.merge("BUDGET_RUBY" => RbConfig.ruby, "BUDGET_MARKER" => @marker,
                             "MISE_PROJECT_ROOT" => @dir, "IOS_DEST" => "fixture-only", "TMPDIR" => @dir)
    [0, 17].each do |compiler_status|
      _, error, status = Open3.capture3(environment.merge("BUDGET_COMPILER_STATUS" => compiler_status.to_s),
                                       "/bin/bash", "-euo", "pipefail", "-c", body, chdir: @dir)
      assert_equal compiler_status.zero? ? 0 : 65, status.exitstatus, error
      assert File.file?(@marker)
      File.unlink(@marker)
    end
    File.write(@free, "0")
    _, error, status = Open3.capture3(environment, "/bin/bash", "-euo", "pipefail", "-c", body, chdir: @dir)
    refute status.success?, error
    refute File.exist?(@marker)
  end
end
