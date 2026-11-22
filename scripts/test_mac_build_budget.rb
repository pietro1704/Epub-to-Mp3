# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
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
    assert_equal 5, shipped.fetch("warn_free_gib")
    refute_includes shipped.keys, "minimum_free_gib"
    refute_includes shipped.keys, "check_interval_seconds"
    floor = shipped.fetch("warn_free_gib") * MacBuildBudget::GIB
    assert_nil MacBuildBudget.evaluate(shipped, free_bytes: 6 * MacBuildBudget::GIB, destination: @dir)
    assert_match(/Free disk below 5 GiB/, MacBuildBudget.evaluate(shipped, free_bytes: floor - 1, destination: @dir))
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
