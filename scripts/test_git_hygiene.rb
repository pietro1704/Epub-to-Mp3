# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class GitHygieneTest < Minitest::Test
  def test_repository_index_contains_no_ignored_artifacts
    repository = File.expand_path("..", __dir__)
    out, err, status = Open3.capture3(@environment, "git", "-C", repository, "ls-files", "-ci", "--exclude-standard", "-z")
    assert status.success?, err
    assert_empty out.split("\0"), "Tracked local artifacts violate .gitignore: #{out.split("\0").first(20).inspect}"
  end

  def setup
    @root = Dir.mktmpdir("epub-git-hygiene-")
    @environment = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    git("init", "--quiet")
    FileUtils.cp(File.expand_path("../.gitignore", __dir__), File.join(@root, ".gitignore"))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    out, err, status = Open3.capture3(@environment, "git", "-C", @root, *args)
    [out, err, status]
  end

  def ignored?(path)
    _, err, status = git("check-ignore", "--no-index", "--quiet", "--", path)
    assert_includes [0, 1], status.exitstatus, err
    status.success?
  end

  def test_secret_environment_is_ignored_but_example_can_be_shared
    %w[.env .env.production ios/EpubToMp3/.env.local].each do |path|
      assert ignored?(path), "secret environment file is visible: #{path}"
    end
    refute ignored?(".env.example")
    refute ignored?("web/.env.production.example")
    %w[web/.env.desktop web/.env.mobile web/.env.production].each do |path|
      refute ignored?(path), "public Vite profile is hidden: #{path}"
    end
    assert ignored?("web/.env.local")
  end

  def test_local_agent_state_and_installed_artifacts_are_ignored
    %w[
      .claude/settings.local.json .claude/agent-memory/session.md
      .claude/night_run_pending.md .claude/night_run_summary.md
      .codex/config.local.toml .codex/sessions/session.jsonl
      .hermes/tools/cargo-ndk/bin/cargo-ndk
      .hermes/snapshots/example/source.swift
      .hermes/snapshots/example/libconverter_ffi.so
      CLAUDE.md.bak-1792081798 .agents/skills/example/SKILL.md.bak-123
      .qa/android/capture.png ios/EpubToMp3/Vendor/site-packages/package/module.py
    ].each { |path| assert ignored?(path), "local artifact is visible: #{path}" }
  end

  def test_session_ledgers_are_local_and_untracking_preserves_their_bytes
    %w[TODO_APP.md handoff.md].each do |path|
      assert ignored?(path), "private session ledger is visible: #{path}"
      absolute = File.join(@root, path)
      File.binwrite(absolute, "private fixture\x00#{path}\n")
      before = File.binread(absolute)
      _, err, status = git("add", "--force", "--", path)
      assert status.success?, err
      _, err, status = git("rm", "--cached", "--quiet", "--", path)
      assert status.success?, err
      assert_equal before, File.binread(absolute)
      assert_empty git("ls-files", "--", path).first
      assert_empty git("ls-files", "--others", "--exclude-standard", "--", path).first
    end
  end

  def test_shared_agent_assets_and_portable_editor_configuration_stay_visible
    %w[
      AGENTS.md CLAUDE.md .ai-memory.toml .ai-jail
      .agents/skills/native-reader-regression/SKILL.md
      .agents/skills/ai-memory-retrieval/SKILL.md
      .agents/skills/example/agents/openai.yaml
      .agents/skills/example/scripts/check.sh
      .codex/skills/goal-plan-execute/SKILL.md
      .claude/skills/example/SKILL.md .claude/hooks/session_start.sh
      .claude/settings.json .hermes/skills/handoff
      .hermes/plans/2026-10-15-git-hygiene.md
      .vscode/extensions.json .vscode/settings.json .vscode/tasks.json
    ].each { |path| refute ignored?(path), "shared asset is hidden: #{path}" }
    assert ignored?(".vscode/local-machine.json")
  end

  def test_untracking_local_artifact_preserves_bytes_and_future_changes_stay_ignored
    path = ".hermes/snapshots/example/source.swift"
    absolute = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, "fixture\x00bytes\n")
    before = File.binread(absolute)
    _, err, status = git("add", "--force", "--", path)
    assert status.success?, err
    # Ignore rules do not remove an already tracked file from the index.
    assert ignored?(path)
    assert_equal "#{path}\n", git("ls-files", "--", path).first
    _, err, status = git("rm", "--cached", "--quiet", "--", path)
    assert status.success?, err
    assert_equal before, File.binread(absolute)
    assert_empty git("ls-files", "--", path).first
    File.binwrite(absolute, "updated fixture\n")
    assert_empty git("ls-files", "--others", "--exclude-standard", "--", path).first
  end

  def test_shared_skill_alias_is_tracked_as_a_relative_symlink
    skill = ".agents/skills/handoff/SKILL.md"
    FileUtils.mkdir_p(File.join(@root, File.dirname(skill)))
    File.write(File.join(@root, skill), "# Shared handoff fixture\n")
    FileUtils.mkdir_p(File.join(@root, ".hermes/skills"))
    File.symlink("../../.agents/skills/handoff", File.join(@root, ".hermes/skills/handoff"))
    _, err, status = git("add", "--", skill, ".hermes/skills/handoff")
    assert status.success?, err
    out, _, status = git("ls-files", "--stage", "--", ".hermes/skills/handoff")
    assert status.success?
    assert_match(/\A120000 /, out)
    assert_equal "../../.agents/skills/handoff", git("show", ":.hermes/skills/handoff").first
    assert_equal File.realpath(File.join(@root, ".agents/skills/handoff")),
                 File.realpath(File.join(@root, ".hermes/skills/handoff"))
  end
end
