# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require "stringio"
require_relative "mac_build_budget"
require_relative "native_job"

class MacBuildBudgetTest < Minitest::Test
  def test_read_only_check_reports_low_space_and_always_exits_zero
    with_stub(:check, nil) { assert_equal 0, MacBuildBudget.main(["check"]) }
    with_stub(:check, "Fixture: destination full") do
      _, error = capture_io { assert_equal 0, MacBuildBudget.main(["check"]) }
      assert_match(/advisory, not a refusal: Fixture: destination full/, error)
    end
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir("mac-build-budget-"))
    @limits = { "version" => 1, "warn_free_gib" => 20 }
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
        "IOS_DERIVED_DATA_PATH" => @dir, "IOS_DISK_GUARD_MAX_TOTAL_MB" => "0" },
        "bash", File.join(__dir__, "ios_disk_guard.sh"), chdir: @dir)
      assert_equal expected, status.exitstatus, error
      assert_equal ["-C", File.expand_path("..", __dir__), "exec", "--", "ruby",
                    File.join(__dir__, "mac_build_budget.rb"), "check", @dir], File.readlines(trace, chomp: true)
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

  # Owner decision 2026-11-22: free space is only reported; no floor stops a build.
  def test_shipped_threshold_only_words_a_note_for_a_nearly_full_disk
    shipped = JSON.parse(File.read(File.expand_path("../config/mac-build-budget.json", __dir__)))
    assert_equal 15, shipped.fetch("warn_free_gib")
    refute_includes shipped.keys, "minimum_free_gib"
    refute_includes shipped.keys, "check_interval_seconds"
    floor = shipped.fetch("warn_free_gib") * MacBuildBudget::GIB
    assert_nil MacBuildBudget.evaluate(shipped, free_bytes: 16 * MacBuildBudget::GIB, destination: @dir)
    assert_match(/Free disk below 15 GiB/, MacBuildBudget.evaluate(shipped, free_bytes: floor - 1, destination: @dir))
  end

  def test_floor_and_host_scope
    floor = 20 * MacBuildBudget::GIB
    assert_nil MacBuildBudget.evaluate(@limits, free_bytes: floor, destination: @dir)
    assert_match(/Free disk below 20 GiB/, MacBuildBudget.evaluate(@limits, free_bytes: floor - 1, destination: @dir))
    release = File.join(@dir, "arch-release")
    assert MacBuildBudget.build_host?("arm64-darwin", arch_release: release)
    refute MacBuildBudget.build_host?("x86_64-linux", arch_release: release)
    File.write(release, "")
    assert MacBuildBudget.build_host?("x86_64-linux", arch_release: release)
    refute MacBuildBudget.build_host?("mingw32", arch_release: release)
  end

  def test_future_directory_uses_the_resolved_parent_volume_without_creating_output
    parent = File.join(@dir, "target disk")
    Dir.mkdir(parent)
    link = File.join(@dir, "linked")
    File.symlink(parent, link)
    destination = File.join(link, "future", "nested")
    snapshot = MacBuildBudget.metrics(destination)
    assert_equal parent, snapshot.fetch(:measured_path)
    assert_equal destination, snapshot.fetch(:destination)
    assert_kind_of Integer, snapshot.fetch(:free_bytes)
    refute File.exist?(File.join(parent, "future"))
  end

  def test_invalid_output_or_unreadable_space_is_a_note_never_a_silent_pass
    invalid = File.join(@dir, "invalid")
    File.symlink("missing", invalid)
    assert_match(/inspection failed/, MacBuildBudget.check(File.join(invalid, "child"), host: "darwin"))
    File.unlink(invalid)
    File.write(invalid, "file")
    assert_match(/inspection failed/, MacBuildBudget.check(File.join(invalid, "child"), host: "darwin"))
    with_stub(:capture, "incomplete row") do
      assert_match(/Missing available space/, MacBuildBudget.check(@dir, host: "darwin"))
    end
  end

  def test_compiler_flags_and_explicit_destination_select_the_output
    cargo = %w[mise -C] + [@dir] + %w[exec -- cargo build --target-dir artifacts]
    assert_equal [File.join(@dir, "artifacts")], NativeJob.build_directories(cargo, nil, inherited: false)
    assert_equal [@dir], NativeJob.build_directories(cargo, @dir, inherited: false)
    assert_equal [@dir], NativeJob.build_directories(["xcodebuild", "-derivedDataPath", @dir], nil, inherited: false)
    assert_equal [@dir], NativeJob.build_directories(["swift", "build", "--scratch-path=#{@dir}"], nil, inherited: false)
    previous = ENV["CARGO_TARGET_DIR"]
    apple = ENV["APPLE_DERIVED_DATA_PATH"]
    ENV["CARGO_TARGET_DIR"] = @dir
    ENV["APPLE_DERIVED_DATA_PATH"] = File.join(@dir, "unrelated-apple-output")
    assert_equal [@dir], NativeJob.build_directories(%w[mise exec -- cargo build], nil, inherited: false)
  ensure
    ENV["CARGO_TARGET_DIR"] = previous
    ENV["APPLE_DERIVED_DATA_PATH"] = apple
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
    skip "Build storage enforcement is specific to macOS and Arch" unless MacBuildBudget.build_host?
    scripts = File.join(@dir, "scripts")
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p([scripts, bin, File.join(@dir, "config"), File.join(@dir, "target"),
                      File.join(@dir, ".build")])
    %w[native_job.rb mac_build_budget.rb].each { |name| FileUtils.cp(File.join(__dir__, name), scripts) }
    # Nested drivers validate the production lock path, isolated in this fixture.
    launcher = File.join(scripts, "native_job.rb")
    File.write(launcher, File.read(launcher).sub(NativeJob::LOCK_PATH, File.join(@dir, "lease")))
    File.write(File.join(@dir, "config/mac-build-budget.json"), JSON.generate(@limits))
    @free = File.join(@dir, "free-kib")
    @marker = File.join(@dir, "child")
    File.write(@free, (30 * 1024**2).to_s)
    @trace = File.join(@dir, "df-paths")
    df = File.join(bin, "df")
    File.write(df, <<~'SH')
      #!/bin/sh
      [ "$1" = "-Pk" ] || exit 2
      printf '%s\n' "$2" >> "$BUDGET_TRACE"
      printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
      available=$(cat "$BUDGET_FREE_STATE")
      if [ "$2" = "${BUDGET_LOW_VOLUME:-}" ]; then available=1; fi
      printf 'fixture 999999999 0 %s 0%% /\n' "$available"
    SH
    File.chmod(0o755, df)
    %w[git du].each do |command|
      path = File.join(bin, command)
      File.write(path, "#!/bin/sh\nexit 23\n")
      File.chmod(0o755, path)
    end
    @env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "BUDGET_FIXTURE_ROOT" => @dir,
             "BUDGET_FREE_STATE" => @free, "BUDGET_TRACE" => @trace, "EPUB_NATIVE_LEASE_FD" => nil, "EPUB_NATIVE_LEASE_PATH" => nil,
             # The local one-job contract; the hosted-runner allowance is tested in test_native_job.rb.
             "GITHUB_ACTIONS" => nil, "RUNNER_ENVIRONMENT" => nil }
    @command = [RbConfig.ruby, File.join(scripts, "native_job.rb"), "--lock-path", File.join(@dir, "lease"),
                "build", "--", RbConfig.ruby, "-e"]
  end

  def test_low_disk_is_a_note_and_the_child_still_runs_to_the_end
    fixture
    File.write(@free, "0")
    _, error, status = Open3.capture3(@env, *@command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert status.success?, error
    assert_match(/advisory, not a refusal: Free disk below/, error)
    assert_equal "ran", File.read(@marker)
  end

  def test_every_destination_is_checked_without_enumerating_caches_or_worktrees
    fixture
    target = File.join(@dir, "target")
    second = File.join(@dir, ".build")
    command = @command.dup.insert(4, "--build-dir", target, "--build-dir", File.join(second, "new"))
    File.write(@free, (20 * 1024**2).to_s)
    _, error, status = Open3.capture3(@env, *command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert status.success?, error
    assert_equal "ran", File.read(@marker)
    assert_equal [target, second], File.readlines(@trace, chomp: true)
    File.unlink(@marker)
    _, error, status = Open3.capture3(@env.merge("BUDGET_LOW_VOLUME" => second), *command,
                                      "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert status.success?, error
    assert_includes error, "advisory, not a refusal: Free disk below"
    assert_includes error, File.join(second, "new")
    assert_equal "ran", File.read(@marker)
  end

  def test_invalid_configuration_is_a_note_and_the_child_still_runs
    fixture
    File.write(File.join(@dir, "config/mac-build-budget.json"), "{}")
    _, error, status = Open3.capture3(@env, *@command, "File.write(ARGV.fetch(0), 'ran')", @marker)
    assert status.success?, error
    assert_match(/inspection failed/, error)
    assert_equal "ran", File.read(@marker)
  end

  def test_budget_allows_child_and_limits_compiler_jobs
    fixture
    _, error, status = Open3.capture3(@env.merge("CARGO_BUILD_JOBS" => "64"), *@command,
                                     'File.write(ARGV.fetch(0), [ENV.fetch("CARGO_BUILD_JOBS"), ENV.fetch("CMAKE_BUILD_PARALLEL_LEVEL")].join(","))', @marker)
    assert status.success?, error
    assert_equal "1,1", File.read(@marker)
  end

  def test_nothing_stops_a_running_child_when_the_disk_floor_is_crossed
    fixture
    target = File.join(@dir, "target")
    command = @command.dup.insert(4, "--build-dir", target)
    program = 'File.write(ARGV.fetch(1), "0"); sleep 1; File.write(ARGV.fetch(0), "finished")'
    _, error, status = Timeout.timeout(20) { Open3.capture3(@env, *command, program, @marker, @free) }
    assert status.success?, error
    refute_match(/Free disk below/, error)
    assert_equal "finished", File.read(@marker)
    assert_equal [target], File.readlines(@trace, chomp: true), "storage is read once, at the start"
  end

  def test_nested_driver_reports_its_additional_destination_without_blocking
    fixture
    target = File.join(@dir, "target")
    driver = File.join(@dir, "driver.rb")
    File.write(driver, <<~'RUBY')
      require_relative 'scripts/native_job'
      NativeJob.build_entrypoint(__FILE__, ARGV, build_dir: ENV.fetch('BUDGET_DRIVER_OUTPUT'))
      File.write(ENV.fetch('BUDGET_DRIVER_STARTED'), Process.pid.to_s)
    RUBY
    env = @env.merge("BUDGET_DRIVER_OUTPUT" => target, "BUDGET_DRIVER_STARTED" => @marker, "BUDGET_LOW_VOLUME" => target)
    _, error, status = Open3.capture3(env, *@command.take(6), RbConfig.ruby, driver)
    assert status.success?, error
    assert_includes error, target
    assert File.exist?(@marker), "the driver went on after the note"
  end

  def test_explicit_parallel_compiler_request_is_not_refused
    fixture
    compiler = File.join(@dir, "bin", "xcodebuild")
    File.write(compiler, "#!/bin/sh\nprintf ran > \"$BUDGET_MARKER\"\n")
    File.chmod(0o755, compiler)
    _, error, status = Open3.capture3(@env.merge("BUDGET_MARKER" => @marker),
                                     *@command.take(6), compiler, "-jobs", "4", "build")
    assert status.success?, error
    assert_equal "ran", File.read(@marker)
  end

  def test_device_and_variant_build_caches_are_preserved_by_cleanup
    caches = %w[.build-device ios/EpubToMp3/.build-device ios/EpubToMp3/.build-release].map do |relative|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "artifact"), "preserve" * 1024)
      path
    end
    with_stub(:worktrees, [@dir]) do
      with_stub(:xcode_caches, []) do
        with_stub(:capture, "") { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
        caches.each { |path| assert File.file?(File.join(path, "artifact")) }
      end
    end
  end

  def test_cleanup_never_removes_shared_rust_outputs
    # A cold release converter-ffi rebuild takes about 11 minutes on the Intel
    # Mac; cleanup must keep both the release and the local-dev dylibs.
    libraries = %w[target/release/libconverter_ffi.dylib target/local-dev/release/libconverter_ffi.dylib].map do |relative|
      path = File.join(@dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "dylib")
      path
    end
    with_stub(:worktrees, [@dir]) do
      with_stub(:xcode_caches, []) do
        with_stub(:capture, "") { MacBuildBudget.prune(lock: File.join(@dir, "lease")) }
        libraries.each { |path| assert File.file?(path), path }
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
    %w[mac:build mac:test:local ios:build ios:device:build converter-ffi:build].each do |name|
      body = task_body(name)
      assert_match(/(?:native_job\.rb["']?\s+(?:--build-dir\s+"[^"]+"\s+)*build\s+--|native_build_command\.rb["']?\s+(?:--build-dir\s+"[^"]+"\s+)*--)/, body, name)
      if name == "converter-ffi:build"
        # Both Cargo commands take NativeJob.build_jobs, which is 1 off GitHub-hosted runners.
        cargo = body.lines.grep(/\[\s*"cargo",/)
        assert_equal 2, cargo.size, body
        cargo.each { |line| assert_match(/"--jobs", NativeJob\.build_jobs\.to_s\]/, line) }
        refute_match(/"--jobs", "(?!1")\d+"/, body)
      else
        assert_match(/(?:-jobs|--jobs)(?:["']\s*,\s*["']|\s+)1/, body, name)
        refute_match(/build_jobs/, body, name)
      end
      refute_match(/-parallelizeTargets/, body, name)
      _, error, status = Open3.capture3("/bin/bash", "-n", stdin_data: body)
      assert status.success?, error
    end
  end

  def test_actual_ios_build_task_runs_through_the_lease_with_fake_compilers
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
                             "MISE_PROJECT_ROOT" => @dir, "APPLE_DERIVED_DATA_PATH" => File.join(@dir, "target"), "IOS_DEST" => "fixture-only", "TMPDIR" => @dir)
    [0, 17].each do |compiler_status|
      _, error, status = Open3.capture3(environment.merge("BUDGET_COMPILER_STATUS" => compiler_status.to_s),
                                       "/bin/bash", "-euo", "pipefail", "-c", body, chdir: @dir)
      assert_equal compiler_status.zero? ? 0 : 65, status.exitstatus, error
      assert File.file?(@marker)
      File.unlink(@marker)
    end
    File.write(@free, "0")
    _, error, status = Open3.capture3(environment, "/bin/bash", "-euo", "pipefail", "-c", body, chdir: @dir)
    assert status.success?, "low space is a note, not a refusal: #{error}"
    assert File.file?(@marker)
  end
end

# Automatic reclaim: synthetic trees only. Old diagnostic bundles go; anything
# that is not one, or that sits under a retained, backup or bundle directory,
# stays.
class BuildStorageReclaimTest < Minitest::Test
  def swap(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, &implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  DAY = 86_400

  def setup
    @dir = File.realpath(Dir.mktmpdir("build-storage-reclaim-"))
    @now = Time.now
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def with_stub(name, value)
    original = MacBuildBudget.method(name)
    MacBuildBudget.define_singleton_method(name) { |*, **| value.respond_to?(:call) ? value.call : value }
    yield
  ensure
    MacBuildBudget.define_singleton_method(name, original)
  end

  def make(relative, days:, directory: true, content: "x")
    path = File.join(@dir, relative)
    if directory
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "payload"), content)
    else
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    time = @now - days * DAY
    File.utime(time, time, path)
    path
  end

  def test_only_expired_diagnostic_bundles_are_candidates
    logs = File.join(@dir, "logs")
    expired = [make("logs/run-a/Test.xcresult", days: 9), make("logs/run-a/system.logarchive", days: 8),
               make("logs/run-b/Fixture.app", days: 10), make("logs/run-b/Fixture.ipa", days: 10, directory: false),
               make("logs/run-b/Fixture.app.dSYM", days: 30)]
    kept = [make("logs/run-c/Recent.xcresult", days: 2),
            make("logs/library-backup-fixture/Old.xcresult", days: 40),
            make("logs/worktree-backup-fixture/Old.app", days: 40),
            make("logs/run-d/Resources.bundle/Old.app", days: 40),
            make("logs/run-e/notes.log", days: 40, directory: false),
            make("logs/run-f/book.epub", days: 40, directory: false),
            make("logs/run-f/book.pdf", days: 40, directory: false),
            make("logs/pinned-run/Old.xcresult", days: 40)]
    File.write(File.join(@dir, "logs/pinned-run", MacBuildBudget::RETAIN_MARKER), "")
    with_epub = make("logs/run-g/Reader.app", days: 40)
    File.write(File.join(with_epub, "fixture.epub"), "book")
    kept << with_epub
    outside = make("outside/Linked.app", days: 40)
    File.symlink(outside, File.join(logs, "run-b/Linked.app"))
    candidates = MacBuildBudget.expired_diagnostics([logs], now: @now)
    assert_equal expired.sort, candidates.sort
    kept.each { |path| refute_includes candidates, path }
  end

  def test_retained_root_is_never_walked
    logs = File.join(@dir, "logs")
    make("logs/Old.xcresult", days: 40)
    File.write(File.join(logs, MacBuildBudget::RETAIN_MARKER), "")
    assert_empty MacBuildBudget.expired_diagnostics([logs], now: @now)
  end

  def test_prune_removes_expired_diagnostics_only_when_asked_and_never_in_dry_run
    logs = File.join(@dir, "logs")
    old = make("logs/run/Test.xcresult", days: 9)
    lock = File.join(@dir, "lease")
    with_stub(:capture, "") do
      with_stub(:legacy_caches, []) do
        with_stub(:diagnostic_roots, [logs]) do
          MacBuildBudget.prune(lock: lock, out: StringIO.new)
          assert File.directory?(old), "plain prune keeps diagnostics"
          out = StringIO.new
          MacBuildBudget.prune(lock: lock, diagnostics: true, dry_run: true, out: out)
          assert File.directory?(old)
          assert_match(/plan: remove expired diagnostic: .*Test\.xcresult/, out.string)
          MacBuildBudget.prune(lock: lock, diagnostics: true, out: StringIO.new)
          refute File.exist?(old)
        end
      end
    end
  end

  def test_prune_dry_run_keeps_derived_data
    cache = File.join(@dir, "EpubToMp3-fixture")
    Dir.mkdir(cache)
    out = StringIO.new
    with_stub(:capture, "") do
      with_stub(:legacy_caches, [cache]) { MacBuildBudget.prune(lock: File.join(@dir, "lease"), dry_run: true, out: out) }
    end
    assert File.directory?(cache)
    assert_match(/plan: remove superseded Xcode cache: .*EpubToMp3-fixture/, out.string)
  end

  def test_locked_and_dirty_worktrees_are_excluded_from_reclaim
    records = [{ path: "/fixture/main", locked: false }, { path: "/fixture/pinned", locked: true },
               { path: "/fixture/dirty", locked: false }, { path: "/fixture/idle", locked: false }]
    with_stub(:worktree_records, records) do
      swap(MacBuildBudget, :clean_checkout?, ->(path) { path != "/fixture/dirty" }) do
        assert_equal %w[/fixture/main /fixture/idle], MacBuildBudget.reclaimable_worktrees
      end
      assert_equal %w[/fixture/main /fixture/dirty /fixture/idle], MacBuildBudget.unlocked_worktrees
    end
  end

  def test_worktree_records_read_locked_entries
    main, pinned, bare = %w[main pinned bare].map { |name| File.join(@dir, name).tap { |path| Dir.mkdir(path) } }
    porcelain = "worktree #{main}\nHEAD abc\nbranch refs/heads/master\n\n" \
                "worktree #{pinned}\nHEAD abc\nbranch refs/heads/pinned\nlocked pinned by owner\n\n" \
                "worktree #{bare}\nHEAD abc\ndetached\nlocked\n\nworktree #{File.join(@dir, 'gone')}\nHEAD abc\n"
    with_stub(:capture, porcelain) do
      assert_equal [{ path: main, locked: false }, { path: pinned, locked: true }, { path: bare, locked: true }],
                   MacBuildBudget.worktree_records
    end
  end

  def test_diagnostic_roots_follow_the_given_checkouts
    main = File.join(@dir, "repo")
    dirty = File.join(@dir, "repo-dirty")
    [File.join(@dir, "repo-logs"), File.join(main, ".reports"), File.join(dirty, ".reports")].each { |path| FileUtils.mkdir_p(path) }
    with_stub(:worktrees, [main, dirty]) do
      ENV.delete(MacBuildBudget::DIAGNOSTICS_ENV)
      assert_equal [File.join(@dir, "repo-logs"), File.join(main, ".reports")], MacBuildBudget.diagnostic_roots([main])
    end
  end

  # Run as `ruby scripts/mac_build_budget.rb reclaim`, the script is loaded by a
  # relative path and then required again through clean_worktrees/native_job.
  def test_loading_the_script_twice_is_silent
    _out, err, status = Open3.capture3(RbConfig.ruby, "-e",
                                       'load "scripts/mac_build_budget.rb"; require_relative "scripts/clean_worktrees"',
                                       chdir: File.expand_path("..", __dir__))
    assert status.success?, err
    assert_empty err
  end

  def test_reclaim_if_low_runs_only_below_the_warning_floor
    calls = []
    with_stub(:policy, { "version" => 1, "warn_free_gib" => 15 }) do
      with_stub(:reclaim, -> { calls << :reclaim }) do
        with_stub(:metrics, { free_bytes: 40 * MacBuildBudget::GIB }) do
          assert_equal 0, MacBuildBudget.main(["reclaim-if-low"]) if RUBY_PLATFORM.include?("darwin")
        end
        assert_empty calls
        with_stub(:metrics, { free_bytes: 3 * MacBuildBudget::GIB }) do
          assert_equal 0, MacBuildBudget.main(["reclaim-if-low"]) if RUBY_PLATFORM.include?("darwin")
        end
      end
    end
    assert_equal(RUBY_PLATFORM.include?("darwin") ? [:reclaim] : [], calls)
  end

  def test_reclaim_dry_run_reaches_every_step_without_removing
    steps = []
    swap(MacBuildBudget, :prune, ->(**options) { steps << [:prune, options.slice(:dry_run, :diagnostics)] }) do
      swap(MacBuildBudget, :reclaim_worktree_builds, ->(**options) { steps << [:worktrees, options.slice(:dry_run)] }) do
        with_stub(:reclaimable_worktrees, []) { MacBuildBudget.reclaim(dry_run: true, out: StringIO.new) }
      end
    end
    assert_equal [[:prune, { dry_run: true, diagnostics: true }], [:worktrees, { dry_run: true }]], steps
  end
end
