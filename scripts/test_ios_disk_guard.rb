# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "securerandom"

# The compatibility disk guard preserves reusable and user-owned build caches.
class IosDiskGuardTest < Minitest::Test
  SCRIPT = File.expand_path("ios_disk_guard.sh", __dir__)

  def setup
    @root = Dir.mktmpdir("ios disk guard ")
    @derived = File.join(@root, "DerivedData")
    @ios_dir = File.join(@root, "EpubToMp3")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # Write real bytes: `du` reports allocated blocks, and a sparse file
  # allocates none, so a size cap would never trigger.
  def make_dir(path, size_mb:, age_days: 0)
    FileUtils.mkdir_p(path)
    payload = File.join(path, "payload.bin")
    File.binwrite(payload, SecureRandom.random_bytes(size_mb * 1024 * 1024))
    mtime = Time.now - (age_days * 86_400)
    File.utime(mtime, mtime, path)
    File.utime(mtime, mtime, payload)
  end

  def run_guard(**overrides)
    env = { "IOS_DISK_GUARD_DERIVED_DATA_ROOT" => @derived, "IOS_DISK_GUARD_IOS_BUILD_DIR" => @ios_dir }
    overrides.each { |name, value| env[name.to_s] = value }
    output, error, status = Open3.capture3(env, "bash", SCRIPT)
    assert status.success?, "guard failed (#{status.exitstatus}): #{output}#{error}"
  end

  def test_preserves_build_dir_older_than_legacy_age_cap
    old_build = File.join(@ios_dir, ".build-old")
    fresh_build = File.join(@ios_dir, ".build-fresh")
    make_dir(old_build, size_mb: 1, age_days: 10)
    make_dir(fresh_build, size_mb: 1)

    run_guard(IOS_DISK_GUARD_MAX_AGE_DAYS: "3", IOS_DISK_GUARD_MAX_TOTAL_MB: "4096")

    assert File.exist?(old_build), "age alone must never authorize cache deletion"
    assert File.exist?(fresh_build), "recently built dir must survive the age cap"
  end

  def test_preserves_all_caches_above_legacy_size_cap
    oldest = File.join(@ios_dir, ".build-a")
    newest = File.join(@ios_dir, ".build-b")
    # Both within the age cap so only the size cap could evict them.
    make_dir(oldest, size_mb: 5, age_days: 1)
    make_dir(newest, size_mb: 5)

    run_guard(IOS_DISK_GUARD_MAX_AGE_DAYS: "30", IOS_DISK_GUARD_MAX_TOTAL_MB: "6")

    assert File.exist?(oldest), "the legacy size cap must never authorize cache deletion"
    assert File.exist?(newest), "newest dir must be kept when it alone fits under the size cap"
  end

  def test_leaves_everything_when_under_both_caps
    build = File.join(@ios_dir, ".build-current")
    make_dir(build, size_mb: 1)

    run_guard(IOS_DISK_GUARD_MAX_AGE_DAYS: "3", IOS_DISK_GUARD_MAX_TOTAL_MB: "4096")

    assert File.exist?(build), "dirs under both caps must never be touched"
  end

  def test_never_touches_other_projects_derived_data
    other_project = File.join(@derived, "SomeOtherApp-abcdef")
    make_dir(other_project, size_mb: 1, age_days: 30)

    run_guard(IOS_DISK_GUARD_MAX_AGE_DAYS: "3", IOS_DISK_GUARD_MAX_TOTAL_MB: "4096")

    assert File.exist?(other_project), "only EpubToMp3-* DerivedData dirs may be touched, never other projects'"
  end
end
