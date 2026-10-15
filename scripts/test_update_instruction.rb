# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require "rbconfig"

class UpdateInstructionTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("epub-instruction-")
    @root = File.join(@directory, "repo")
    FileUtils.mkdir_p(@root)
    @target = File.join(@root, "CLAUDE.md")
    @baseline = File.join(@directory, "baseline")
    @before = "prefix\nold instruction\nsuffix\n"
    File.binwrite(@target, @before)
    File.binwrite(@baseline, @before)
    File.binwrite(File.join(@directory, "old"), "old instruction")
    File.binwrite(File.join(@directory, "new"), "new instruction")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def update(destination: @target, digest: Digest::SHA256.hexdigest(@before))
    Open3.capture3(RbConfig.ruby, File.expand_path("update_instruction.rb", __dir__),
                  "--root", @root, "--destination", destination,
                  "--baseline", @baseline, "--sha256", digest,
                  "--old", File.join(@directory, "old"), "--new", File.join(@directory, "new"))
  end

  def test_exact_patch_preserves_adjacent_bytes_and_repeat_preserves_mtime
    File.chmod(0o640, @target)
    File.symlink("CLAUDE.md", File.join(@root, "AGENTS.md"))
    output, error, status = update(destination: File.join(@root, "AGENTS.md"))
    assert status.success?, error
    assert_match(/Updated/, output)
    assert_equal @before.sub("old instruction", "new instruction"), File.binread(@target)
    assert_equal 0o640, File.stat(@target).mode & 0o777
    assert_equal "CLAUDE.md", File.readlink(File.join(@root, "AGENTS.md"))
    timestamp = Time.at(1_600_000_000)
    File.utime(timestamp, timestamp, @target)
    output, error, status = update(destination: File.join(@root, "AGENTS.md"))
    assert status.success?, error
    assert_match(/Already applied/, output)
    assert_equal timestamp, File.mtime(@target)
  end

  def test_target_drift_is_rejected_without_writing
    File.binwrite(@target, @before + "concurrent edit\n")
    original = File.binread(@target)
    _, error, status = update
    refute status.success?
    assert_match(/differs from baseline/, error)
    assert_equal original, File.binread(@target)
  end

  def test_baseline_hash_mismatch_is_rejected
    _, error, status = update(digest: "0" * 64)
    refute status.success?
    assert_match(/baseline SHA256/, error)
    assert_equal @before, File.binread(@target)
  end

  def test_missing_duplicate_and_empty_matches_are_rejected
    ["missing", "old instruction\nold instruction", ""].each do |old|
      baseline = old.include?("\n") ? old : @before
      File.binwrite(@baseline, baseline)
      File.binwrite(@target, baseline)
      File.binwrite(File.join(@directory, "old"), old.include?("\n") ? "old instruction" : old)
      _, _, status = update(digest: Digest::SHA256.hexdigest(baseline))
      refute status.success?
      assert_equal baseline, File.binread(@target)
    end
  end

  def test_symlink_and_direct_destination_escapes_are_rejected
    outside = File.join(@directory, "outside")
    File.binwrite(outside, @before)
    alias_path = File.join(@root, "escape")
    File.symlink(outside, alias_path)
    [outside, alias_path].each do |path|
      _, error, status = update(destination: path)
      refute status.success?
      assert_match(/outside declared root/, error)
      assert_equal @before, File.binread(outside)
    end
  end

  def test_overlapping_matches_are_ambiguous
    File.binwrite(@baseline, "aaa")
    File.binwrite(@target, "aaa")
    File.binwrite(File.join(@directory, "old"), "aa")
    _, error, status = update(digest: Digest::SHA256.hexdigest("aaa"))
    refute status.success?
    assert_match(/exactly one occurrence/, error)
    assert_equal "aaa", File.binread(@target)
  end

  def test_contended_directory_lock_blocks_without_writing
    File.open(@root, File::RDONLY) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      _, error, status = update
      refute status.success?
      assert_match(/Another instruction update/, error)
      assert_equal @before, File.binread(@target)
    end
  end

  def test_missing_cli_arguments_fail
    _, error, status = Open3.capture3(RbConfig.ruby, File.expand_path("update_instruction.rb", __dir__))
    refute status.success?
    assert_match(/missing argument/, error)
  end
end
