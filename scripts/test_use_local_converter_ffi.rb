# frozen_string_literal: true

# Host-only coverage for the Debug macOS local-dev embedding step. It runs the
# real script with a fixture Xcode environment; no Xcode build is started.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class UseLocalConverterFfiTest < Minitest::Test
  SCRIPT = File.expand_path("use_local_converter_ffi.sh", __dir__)

  def setup
    @root = File.realpath(Dir.mktmpdir("use local ffi "))
    FileUtils.mkdir_p(File.join(@root, "scripts"))
    FileUtils.cp(SCRIPT, File.join(@root, "scripts"))
    @release = write("target/release/libconverter_ffi.dylib", "release bytes")
    @local = write("target/local-dev/release/libconverter_ffi.dylib", "local-dev bytes")
    @embedded = write("Build/Products/Debug/EpubToMp3.app/Contents/Frameworks/libconverter_ffi.dylib", "release bytes")
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "codesign"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CODESIGN_LOG\"\n")
    File.chmod(0o755, File.join(@bin, "codesign"))
    @codesign_log = File.join(@root, "codesign.log")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def run_step(configuration: "Debug", platform: "macosx", requested: nil, signing: "NO")
    environment = {
      "PATH" => "#{@bin}:/usr/bin:/bin", "CODESIGN_LOG" => @codesign_log,
      "PLATFORM_NAME" => platform, "CONFIGURATION" => configuration,
      "TARGET_BUILD_DIR" => File.join(@root, "Build/Products/Debug"),
      "FRAMEWORKS_FOLDER_PATH" => "EpubToMp3.app/Contents/Frameworks",
      "DERIVED_FILE_DIR" => File.join(@root, "Build/Intermediates/DerivedSources"),
      "CODE_SIGNING_ALLOWED" => signing, "EXPANDED_CODE_SIGN_IDENTITY" => "-",
      "EPUB2MP3_LOCAL_FFI_DYLIB" => requested
    }
    Open3.capture3(environment, "/bin/bash", File.join(@root, "scripts/use_local_converter_ffi.sh"))
  end

  def test_without_the_setting_release_bytes_are_untouched
    _, error, status = run_step
    assert status.success?, error
    assert_equal "release bytes", File.read(@embedded)
    refute File.exist?(@codesign_log)
  end

  def test_debug_macos_embeds_local_dev_then_restores_release_when_unset
    _, error, status = run_step(requested: @local)
    assert status.success?, error
    assert_equal "local-dev bytes", File.read(@embedded)
    _, error, status = run_step
    assert status.success?, error
    assert_equal "release bytes", File.read(@embedded)
  end

  def test_release_configuration_is_refused_and_keeps_release_bytes
    _, error, status = run_step(configuration: "Release", requested: @local)
    refute status.success?
    assert_includes error, "only for Debug builds"
    assert_equal "release bytes", File.read(@embedded)
  end

  def test_other_paths_are_refused
    other = write("elsewhere/libconverter_ffi.dylib", "foreign")
    _, error, status = run_step(requested: other)
    refute status.success?
    assert_includes error, "must be the built"
    assert_equal "release bytes", File.read(@embedded)
  end

  def test_non_macos_platforms_ignore_the_step_and_refuse_the_setting
    _, error, status = run_step(platform: "iphoneos")
    assert status.success?, error
    _, error, status = run_step(platform: "iphoneos", requested: @local)
    refute status.success?
    assert_includes error, "only for macOS builds"
    assert_equal "release bytes", File.read(@embedded)
  end

  def test_signed_builds_resign_the_replaced_library
    _, error, status = run_step(requested: @local, signing: "YES")
    assert status.success?, error
    assert_includes File.read(@codesign_log), "--force --sign - --timestamp=none #{@embedded}"
  end
end
