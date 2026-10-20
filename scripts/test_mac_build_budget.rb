# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require_relative "mac_build_budget"

class MacBuildBudgetTest < Minitest::Test
  def setup
    @dir = File.realpath(Dir.mktmpdir("mac-build-budget-"))
    @limits = { "version" => 1, "minimum_free_gib" => 20, "maximum_cache_gib" => 12,
                "check_interval_seconds" => 1 }
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
      assert_nil MacBuildBudget.evaluate(@limits, **snapshot)
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
end
