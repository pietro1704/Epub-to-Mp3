# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require_relative "clean_worktrees"

class CleanWorktreesTest < Minitest::Test
  BUILD = "ios/EpubToMp3/.build"

  def setup
    @tmp = File.realpath(Dir.mktmpdir("clean-worktrees-"))
    @main = File.join(@tmp, "main")
    @lock = File.join(@tmp, "lease.lock")
    FileUtils.mkdir_p(@main)
    git(@main, "init", "-q", "-b", "master")
    File.write(File.join(@main, "a.txt"), "a")
    git(@main, "add", ".")
    git(@main, "commit", "-q", "-m", "init")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def git(dir, *args)
    out, status = Open3.capture2e({ "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
                                    "GIT_COMMITTER_EMAIL" => "t@t" }, "git", *args, chdir: dir)
    assert status.success?, out
    out
  end

  def add_worktree(name, build_bytes: 2048)
    path = File.join(@tmp, name)
    git(@main, "worktree", "add", "-q", "-b", name, path)
    dir = File.join(path, BUILD)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "artifact"), "x" * build_bytes)
    path
  end

  def age(path, hours)
    t = Time.now - hours * 3600
    Dir.glob(File.join(path, "*"), File::FNM_DOTMATCH).each { |f| File.utime(t, t, f) if File.file?(f) }
    git_dir = git(path, "rev-parse", "--git-path", "logs/HEAD").strip
    File.utime(t, t, File.expand_path(git_dir, path))
  end

  def run_clean(states, processes: [], dry_run: false)
    out = StringIO.new
    code = CleanWorktrees.run(root: @main, lock: @lock, dry_run: dry_run, out: out,
                              pr_state: ->(_root, branch) { states.fetch(branch, :unknown) },
                              processes: -> { processes })
    [code, out.string]
  end

  def test_removes_worktree_with_merged_pr_and_only_build_dirs
    path = add_worktree("done")
    code, out = run_clean({ "done" => :done })
    assert_equal 0, code
    refute File.exist?(path)
    assert_match(/removed .*done/, out)
    assert_match(/freed/, out)
    assert File.directory?(@main)
    assert_includes git(@main, "branch"), "done"
  end

  def test_never_removes_tracked_changes_and_reports
    path = add_worktree("dirty")
    File.write(File.join(path, "a.txt"), "changed")
    _, out = run_clean({ "dirty" => :done })
    assert File.exist?(path)
    assert_match(/REPORT: .*dirty.*tracked change/, out)
  end

  def test_unknown_and_open_pr_never_remove
    open_wt = add_worktree("open")
    unknown = add_worktree("mystery")
    _, out = run_clean({ "open" => :open })
    assert File.exist?(open_wt)
    assert File.exist?(unknown)
    assert_match(/skip/, out)
  end

  def test_gh_failure_is_unknown
    path = add_worktree("offline")
    out = StringIO.new
    CleanWorktrees.run(root: @main, lock: @lock, out: out, processes: -> { [] },
                       pr_state: ->(_r, _b) { :unknown })
    assert File.exist?(path)
  end

  def test_other_untracked_files_block_removal
    path = add_worktree("notes")
    File.write(File.join(path, "scratch.md"), "mine")
    _, out = run_clean({ "notes" => :done })
    assert File.exist?(path)
    assert_match(/untracked files remain/, out)
  end

  def test_idle_worktree_loses_only_build_dirs
    path = add_worktree("idle")
    age(path, 30)
    code, out = run_clean({ "idle" => :open })
    assert_equal 0, code
    assert File.exist?(File.join(path, "a.txt"))
    refute File.exist?(File.join(path, BUILD))
    assert_match(/delete build dirs|removed/, out)
  end

  def test_recent_worktree_keeps_build_dirs
    path = add_worktree("fresh")
    run_clean({ "fresh" => :open })
    assert File.exist?(File.join(path, BUILD, "artifact"))
  end

  def test_running_process_inside_worktree_skips_it
    path = add_worktree("busy")
    age(path, 30)
    procs = [{ args: "swift-build", cwd: File.join(path, "ios/EpubToMp3") }]
    # swift-build is not a lease-refusing compiler, so only this worktree is skipped.
    _, out = run_clean({ "busy" => :done }, processes: procs)
    assert File.exist?(File.join(path, BUILD, "artifact"))
    assert_match(/build process running/, out)
  end

  def test_process_with_args_inside_worktree_skips_it
    path = add_worktree("args")
    procs = [{ args: "xcodebuild -project #{path}/x.xcodeproj", cwd: "/" }]
    assert_raises(CleanWorktrees::Refused) { run_clean({ "args" => :done }, processes: procs) }
    assert File.exist?(path)
  end

  def test_compiler_anywhere_refuses_entirely
    path = add_worktree("any")
    assert_raises(CleanWorktrees::Refused) { run_clean({ "any" => :done }, processes: [{ args: "cargo build", cwd: "/elsewhere" }]) }
    assert File.exist?(path)
  end

  def test_held_lease_refuses_entirely
    path = add_worktree("held")
    File.open(@lock, File::RDWR | File::CREAT) do |lease|
      lease.flock(File::LOCK_EX)
      assert_raises(CleanWorktrees::Refused) { run_clean({ "held" => :done }) }
    end
    assert File.exist?(path)
  end

  def test_dry_run_changes_nothing
    path = add_worktree("plan")
    code, out = run_clean({ "plan" => :done }, dry_run: true)
    assert_equal 0, code
    assert File.exist?(path)
    assert_match(/plan: remove worktree: .*plan/, out)
    assert_match(/dry run/, out)
  end

  def test_never_lists_main_checkout
    items = CleanWorktrees.plan(@main, pr_state: ->(*) { :done }, processes: [])
    assert_empty items
  end

  def test_locked_worktree_is_skipped
    path = add_worktree("pinned")
    git(@main, "worktree", "lock", path)
    _, out = run_clean({ "pinned" => :done })
    assert File.exist?(path)
    assert_match(/locked/, out)
  end

  def test_gh_pr_state_without_gh_is_unknown
    original = ENV["PATH"]
    ENV["PATH"] = "/nonexistent"
    assert_equal :unknown, CleanWorktrees.gh_pr_state(@main, "x")
  ensure
    ENV["PATH"] = original
  end
end

# The automatic mode used by build-storage reclaim: build output of worktrees
# idle for 72 h only, never a worktree removal, never a dirty or locked one.
class CleanWorktreesTest
  def swap(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, &implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def run_auto(processes: [], dry_run: false)
    out = StringIO.new
    code = CleanWorktrees.run(root: @main, lock: @lock, dry_run: dry_run, out: out, auto: true,
                              pr_state: ->(*) { flunk "automatic mode never asks GitHub" },
                              processes: -> { processes })
    [code, out.string]
  end

  def add_rust_output(path)
    kept = %w[target/native-prebuilt/lib.a target/onnxruntime-macos-prebuilt/x86_64/lib.dylib
              target/espeak-data/release/data target/release/libconverter_ffi.dylib
              target/local-dev/release/libconverter_ffi.dylib]
    removed = %w[target/debug/deps/a.rlib target/local-dev/debug/incremental/b]
    # target/ is ignored in the real repository.
    File.write(File.join(@main, ".git/info/exclude"), "target/\n", mode: "a")
    (kept + removed).each do |relative|
      FileUtils.mkdir_p(File.dirname(File.join(path, relative)))
      File.write(File.join(path, relative), "x")
    end
    [kept.map { |r| File.join(path, r) }, %w[target/debug target/local-dev/debug].map { |r| File.join(path, r) }]
  end

  def test_auto_clears_build_and_rust_debug_output_after_72_hours_keeping_prebuilt_and_release
    path = add_worktree("idle")
    kept, removed = add_rust_output(path)
    age(path, 80)
    code, out = run_auto
    assert_equal 0, code
    assert File.directory?(path)
    refute File.exist?(File.join(path, BUILD))
    removed.each { |dir| refute File.exist?(dir), dir }
    kept.each { |file| assert File.file?(file), file }
    assert_match(/removed .*idle \(clean_build/, out)
  end

  def test_auto_keeps_output_younger_than_72_hours
    path = add_worktree("recent")
    _, removed = add_rust_output(path)
    age(path, 48)
    run_auto
    assert File.directory?(File.join(path, BUILD))
    removed.each { |dir| assert File.directory?(dir), dir }
  end

  def test_auto_never_removes_a_worktree_even_when_its_pr_is_done
    path = add_worktree("merged")
    age(path, 200)
    _, out = run_auto
    assert File.directory?(path)
    refute_match(/remove worktree/, out)
  end

  def test_auto_skips_tracked_and_untracked_changes
    tracked = add_worktree("tracked")
    File.write(File.join(tracked, "a.txt"), "changed")
    untracked = add_worktree("untracked")
    File.write(File.join(untracked, "notes.txt"), "new")
    [tracked, untracked].each { |path| age(path, 200) }
    _, out = run_auto
    [tracked, untracked].each { |path| assert File.directory?(File.join(path, BUILD)), path }
    assert_match(/skip: .*tracked - uncommitted files/, out)
    assert_match(/skip: .*untracked - uncommitted files/, out)
  end

  def test_auto_skips_locked_and_busy_worktrees
    locked = add_worktree("pinned")
    git(@main, "worktree", "lock", locked)
    busy = add_worktree("busy")
    [locked, busy].each { |path| age(path, 200) }
    run_auto(processes: [{ args: "DeviceWorkflow run", cwd: busy }])
    [locked, busy].each { |path| assert File.directory?(File.join(path, BUILD)), path }
  end

  def test_auto_dry_run_changes_nothing
    path = add_worktree("idle")
    _, removed = add_rust_output(path)
    age(path, 80)
    _, out = run_auto(dry_run: true)
    assert File.directory?(File.join(path, BUILD))
    removed.each { |dir| assert File.directory?(dir), dir }
    assert_match(/plan: delete build dirs/, out)
  end

  def test_auto_flag_parses
    calls = []
    swap(CleanWorktrees, :run, ->(**options) { calls << options.slice(:auto, :dry_run); 0 }) do
      CleanWorktrees.main(%w[--auto --dry-run], root: @main)
    end
    assert_equal [{ auto: true, dry_run: true }], calls
  end
end
