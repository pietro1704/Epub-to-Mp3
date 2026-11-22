# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class StageNativeNoticesTest < Minitest::Test
  SCRIPT = File.join(__dir__, "stage_native_notices.rb")
  NOTICE = "native/THIRD_PARTY_NOTICES.md"
  GPL = "native/licenses/espeak-ng-GPL-3.0.txt"
  MIT = "native/vendor/espeak-rs/LICENSE"
  ESPEAK = "native/vendor/espeak-rs-sys/espeak-ng"
  UNICODE = "#{ESPEAK}/src/ucd-tools/COPYING.UCD"
  SONIC = "#{ESPEAK}/src/sonic/LICENSE"
  DEPS = "#{ESPEAK}/cmake/deps.cmake"
  WORKFLOW = ".github/workflows/release-desktop.yml"
  SONIC_PIN = "fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104"
  NOTICES = [NOTICE, GPL, MIT, UNICODE, SONIC].freeze

  def setup
    @tmp = Dir.mktmpdir("native notices fixture ")
    @repo = File.join(@tmp, "release source")
    FileUtils.mkdir_p(@repo)
    @destination = File.join(@tmp, "ThirdPartyNotices")
    git("init", "-q")
    git("config", "core.autocrlf", "false")
    (NOTICES + [WORKFLOW]).each { |path| write(path, "fixture #{path}\r\n") }
    write(DEPS, "add_library(sonic OBJECT src/sonic/sonic.c)\n")
    @release = commit("Release with vendored Sonic")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_stages_only_committed_bytes_and_links_to_the_exact_release
    write(NOTICE, "new source on the checkout\n")
    head = commit("Later source")
    write(NOTICE, "uncommitted source\n")
    git("replace", @release, head)
    git("remote", "add", "origin", "https://example.invalid/untrusted/mirror.git")

    output, status = stage(@release)
    assert status.success?, output
    paths = Dir.glob("**/*", base: @destination).select { |path| File.file?(File.join(@destination, path)) }
    assert_equal (NOTICES + ["SOURCE.md"]).sort, paths.sort
    NOTICES.each do |path|
      assert_equal "fixture #{path}\r\n", File.binread(File.join(@destination, path))
    end

    source = File.read(File.join(@destination, "SOURCE.md"))
    url = "https://github.com/pietro1704/Epub-to-Mp3"
    assert_includes source, "Source commit: #{@release}"
    assert_includes source, "#{url}/tree/#{@release}"
    assert_includes source, "#{url}/archive/#{@release}.tar.gz"
    assert_includes source, "#{url}/blob/#{@release}/#{WORKFLOW}"
    assert_includes source, "#{url}/blob/#{@release}/#{NOTICE}"
    refute_includes source, head
    refute_includes source, "example.invalid"
  end

  def test_keeps_historical_external_sonic_pin
    verified_license = File.expand_path("../#{SONIC}", __dir__)
    git("hash-object", "-w", verified_license)
    File.delete(File.join(@repo, SONIC))
    write(DEPS, <<~CMAKE)
      FetchContent_Declare(sonic-git
        GIT_REPOSITORY https://github.com/waywardgeek/sonic.git
        GIT_TAG #{SONIC_PIN}
      )
    CMAKE
    historical_release = commit("Release with external Sonic fallback")

    output, status = stage(historical_release)
    assert status.success?, output
    source = File.read(File.join(@destination, "SOURCE.md"))
    assert_includes source, "https://github.com/waywardgeek/sonic/tree/#{SONIC_PIN}"
    assert_includes source, "https://github.com/waywardgeek/sonic/blob/#{SONIC_PIN}/LICENSE"
    assert_equal File.binread(verified_license), File.binread(File.join(@destination, SONIC))
  end

  def test_refuses_an_external_sonic_revision_without_a_verified_license
    write(DEPS, "GIT_REPOSITORY https://github.com/waywardgeek/sonic.git\nGIT_TAG #{'b' * 40}\n")
    assert_rejected(commit("Release with a different external Sonic revision"), "Unknown external Sonic license revision")
  end

  def test_refuses_missing_sonic_license_before_writing_the_destination
    File.delete(File.join(@repo, SONIC))
    broken_release = commit("Release without the vendored Sonic license")
    write(SONIC, "present only in the working tree")

    assert_rejected(broken_release, SONIC)
  end

  def test_refuses_empty_unicode_license_before_writing_the_destination
    write(UNICODE, "")
    assert_rejected(commit("Release with an empty Unicode notice"), UNICODE)
  end

  def test_refuses_a_non_commit_or_abbreviated_sha
    assert_rejected(git("rev-parse", "HEAD:#{NOTICE}").strip, "exact release commit")
    assert_rejected(@release[0, 12], "exact release commit")
  end

  def test_preserves_a_preexisting_destination
    FileUtils.mkdir_p(@destination)
    old_file = File.join(@destination, "existing")
    File.write(old_file, "preserve\n")

    output, status = stage(@release)
    refute status.success?, output
    assert_includes output, "already exists"
    assert_equal ["existing"], Dir.children(@destination)
    assert_equal "preserve\n", File.read(old_file)
  end

  private

  def assert_rejected(sha, message)
    output, status = stage(sha)
    refute status.success?, output
    assert_includes output, message
    refute File.exist?(@destination)
    assert_equal ["release source"], Dir.children(@tmp)
  end

  def write(path, bytes)
    absolute = File.join(@repo, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, bytes)
  end

  def commit(message)
    git("add", "-A")
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", message)
    git("rev-parse", "HEAD").strip
  end

  def git(*args)
    output, status = Open3.capture2e("git", "-C", @repo, *args)
    raise "Git failed: #{output}" unless status.success?

    output
  end

  def stage(sha)
    Open3.capture2e(RbConfig.ruby, SCRIPT, @repo, sha, @destination)
  end
end
