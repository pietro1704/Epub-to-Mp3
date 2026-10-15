# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "rbconfig"
require "digest"

class ScopedGitIndexTest < Minitest::Test
  TOOL = File.expand_path("scoped_git_index.rb", __dir__)

  def setup
    @root = Dir.mktmpdir("scoped-index-")
    @manifest = File.join(@root, "manifest.json")
    @env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    git("init", "--quiet")
    git("config", "user.name", "Fixture")
    git("config", "user.email", "fixture@example.invalid")
    write("owned", "old\n")
    write("other", "other\n")
    git("add", ".")
    git("commit", "--quiet", "-m", "fixture")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    out, err, status = Open3.capture3(@env, "git", "-C", @root, *args)
    assert status.success?, "git #{args.inspect}: #{err}"
    out
  end

  def write(path, bytes)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.binwrite(File.join(@root, path), bytes)
  end

  def cli(*args, env: {})
    Open3.capture3(@env.merge(env), RbConfig.ruby, TOOL, *args, chdir: @root)
  end

  def ok(*args, **options)
    out, err, status = cli(*args, **options)
    assert status.success?, "#{args.inspect}: #{out}#{err}"
    out
  end

  def reject(*args)
    index = File.binread(File.join(@root, ".git/index"))
    _, err, status = cli(*args)
    refute status.success?, "unexpected success: #{args.inspect}"
    refute_empty err
    assert_equal index, File.binread(File.join(@root, ".git/index"))
  end

  def test_stage_and_verify_preserve_unrelated_dirty_bytes_and_special_names
    paths = ["owned", "space name", "-option", "line\nbreak"]
    paths.each { |path| write(path, "new #{path}\n") }
    write("other", "pending unrelated\n")
    baseline = File.binread(File.join(@root, "other"))
    ok("capture", @manifest, "--", *paths)
    ok("stage", @manifest)
    ok("verify", @manifest)
    assert_equal paths.sort, git("diff", "--cached", "--name-only", "-z").split("\0").sort
    assert_equal baseline, File.binread(File.join(@root, "other"))
    assert_equal "new owned\n", File.binread(File.join(@root, "owned"))
  end

  def test_untrack_preserves_bytes_and_symlink_identity
    File.symlink("owned", File.join(@root, "link"))
    git("add", "link")
    git("commit", "--quiet", "-m", "link")
    ok("capture", @manifest, "--", "owned", "link")
    ok("untrack", @manifest)
    ok("verify", @manifest)
    assert_empty git("ls-files", "--", "owned", "link")
    assert_equal "old\n", File.binread(File.join(@root, "owned"))
    assert_equal "owned", File.readlink(File.join(@root, "link"))
  end

  def test_prepared_source_stages_reviewed_slice_without_changing_dirty_worktree
    write("owned", "full concurrent work\n")
    source = File.join(@root, "prepared")
    File.write(source, "reviewed slice\n")
    ok("capture", @manifest, "--stage-from", "owned", source, "--", "owned")
    ok("stage", @manifest)
    ok("verify", @manifest)
    assert_equal "reviewed slice\n", git("show", ":owned")
    assert_equal "full concurrent work\n", File.read(File.join(@root, "owned"))
  end

  def test_stale_worktree_source_index_and_head_are_rejected
    %w[worktree source index head].each do |kind|
      manifest = File.join(@root, "#{kind}.json")
      source = File.join(@root, "prepared-#{kind}")
      File.write(source, "reviewed\n")
      ok("capture", manifest, "--stage-from", "owned", source, "--", "owned")
      case kind
      when "worktree" then write("owned", "changed\n")
      when "source" then File.write(source, "changed source\n")
      when "index" then git("add", "--", "owned") # Force a real staged entry change.
      when "head" then git("commit", "--quiet", "--allow-empty", "-m", "concurrent")
      end
      if kind == "index"
        write("other", "changed unrelated\n")
        git("add", "other")
      end
      reject("stage", manifest)
      git("reset", "--quiet", "HEAD", "--", "owned", "other")
    end
  end

  def test_preexisting_staged_changes_and_wrong_repository_are_rejected
    write("other", "staged unrelated\n")
    git("add", "other")
    reject("capture", @manifest, "--", "owned")
    git("reset", "--quiet", "HEAD", "--", "other")
    ok("capture", @manifest, "--", "owned")
    Dir.mktmpdir("wrong-index-") do |other|
      _, _, status = Open3.capture3(@env, "git", "init", "--quiet", other)
      assert status.success?
      _, err, status = Open3.capture3(@env, RbConfig.ruby, TOOL, "stage", @manifest, chdir: other)
      refute status.success?
      assert_match(/identity|repository/, err)
    end
  end

  def test_existing_index_lock_is_preserved_and_capture_is_immutable
    write("owned", "new\n")
    ok("capture", @manifest, "--", "owned")
    original = File.binread(@manifest)
    reject("capture", @manifest, "--", "other")
    assert_equal original, File.binread(@manifest)
    lock = File.join(@root, ".git/index.lock")
    File.write(lock, "another owner\n")
    reject("stage", @manifest)
    assert_equal "another owner\n", File.read(lock)
  end

  def test_traversal_directory_and_symlink_parent_are_rejected
    File.symlink(@root, File.join(@root, "alias"))
    ["../outside", @root, ".git/index", ".GIT/index", ".", "alias/owned"].each do |path|
      reject("capture", @manifest, "--", path)
    end
  end

  def test_verify_rejects_later_scope_and_worktree_changes
    write("owned", "new\n")
    ok("capture", @manifest, "--", "owned")
    ok("stage", @manifest)
    write("other", "unrelated staged\n")
    git("add", "other")
    reject("verify", @manifest)
    git("reset", "--quiet", "HEAD", "--", "other")
    write("owned", "late edit\n")
    reject("verify", @manifest)
  end

  def test_git_environment_cannot_redirect_mutation
    write("owned", "new\n")
    poisoned = File.join(@root, "poisoned-index")
    ok("capture", @manifest, "--", "owned", env: { "GIT_INDEX_FILE" => poisoned })
    ok("stage", @manifest, env: { "GIT_INDEX_FILE" => poisoned })
    refute File.exist?(poisoned)
    assert_equal "new\n", git("show", ":owned")
  end

  def test_deleted_file_and_literal_symlink_can_be_staged
    File.unlink(File.join(@root, "owned"))
    File.symlink("missing-target", File.join(@root, "link"))
    ok("capture", @manifest, "--", "owned", "link")
    ok("stage", @manifest)
    ok("verify", @manifest)
    assert_equal "missing-target", git("show", ":link")
    assert_match(/120000/, git("ls-files", "--stage", "--", "link"))
    assert_empty git("ls-files", "--", "owned")
  end

  def test_cli_uses_repository_index_from_a_nested_working_directory
    FileUtils.mkdir_p(File.join(@root, "nested/deep"))
    write("owned", "nested invocation\n")
    %w[capture stage verify].each do |operation|
      args = [operation, @manifest]
      args += ["--", "owned"] if operation == "capture"
      out, err, status = Open3.capture3(@env, RbConfig.ruby, TOOL, *args, chdir: File.join(@root, "nested/deep"))
      assert status.success?, "#{out}#{err}"
    end
    assert_equal "nested invocation\n", git("show", ":owned")
  end

  def test_corrupted_candidate_and_candidate_outside_scope_are_rejected_atomically
    write("owned", "new\n")
    ok("capture", @manifest, "--", "owned")
    original = File.binread(@manifest)
    data = JSON.parse(original)
    data.fetch("images").fetch("stage")["sha256"] = "0" * 64
    File.write(@manifest, JSON.generate(data))
    reject("stage", @manifest)
    refute File.exist?(File.join(@root, ".git/index.lock"))
    File.binwrite(@manifest, original)
    write("other", "forbidden staging\n")
    other_manifest = File.join(@root, "other-manifest.json")
    ok("capture", other_manifest, "--", "owned", "other")
    data = JSON.parse(original)
    data["images"]["stage"] = JSON.parse(File.read(other_manifest)).fetch("images").fetch("stage")
    File.write(@manifest, JSON.generate(data))
    reject("stage", @manifest)
    refute File.exist?(File.join(@root, ".git/index.lock"))
    assert_equal "forbidden staging\n", File.read(File.join(@root, "other"))
  end

  def test_git_add_failure_does_not_publish_manifest_or_mutate_index
    write(".gitignore", "ignored\n")
    write("ignored", "local bytes\n")
    reject("capture", @manifest, "--", "ignored")
    refute File.exist?(@manifest)
    refute File.exist?(File.join(@root, ".git/index.lock"))
    assert_equal "local bytes\n", File.read(File.join(@root, "ignored"))
  end

  def test_self_consistent_in_scope_candidate_cannot_replace_reviewed_contents
    source_a = File.join(@root, "prepared-a")
    source_b = File.join(@root, "prepared-b")
    File.write(source_a, "reviewed slice A\n")
    File.write(source_b, "unreviewed slice B\n")
    other_manifest = File.join(@root, "other-manifest.json")
    ok("capture", @manifest, "--stage-from", "owned", source_a, "--", "owned")
    ok("capture", other_manifest, "--stage-from", "owned", source_b, "--", "owned")
    original = JSON.parse(File.read(@manifest))
    original["images"]["stage"] = JSON.parse(File.read(other_manifest)).fetch("images").fetch("stage")
    File.write(@manifest, JSON.generate(original))
    reject("stage", @manifest)
    assert_equal "old\n", File.read(File.join(@root, "owned"))
    assert_empty git("diff", "--cached", "--name-only")
  end

  def test_branch_switch_at_same_commit_changes_repository_identity
    write("owned", "new\n")
    ok("capture", @manifest, "--", "owned")
    git("branch", "another-branch")
    git("symbolic-ref", "HEAD", "refs/heads/another-branch")
    reject("stage", @manifest)
  end
end
