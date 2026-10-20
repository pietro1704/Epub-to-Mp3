require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class BundleOnnxruntimeAppleTest < Minitest::Test
  SCRIPT = File.expand_path('bundle_onnxruntime_apple.sh', __dir__)

  def setup
    @root = Dir.mktmpdir('onnx bundle fixture with spaces ')
    FileUtils.mkdir_p(File.join(@root, 'scripts'))
    @script = File.join(@root, 'scripts', File.basename(SCRIPT))
    FileUtils.cp(SCRIPT, @script)
    @bin = File.join(@root, 'fake tools')
    FileUtils.mkdir_p(@bin)
    @products = File.join(@root, 'build products')
    @frameworks = 'Host app.app/Contents/Frameworks'
    FileUtils.mkdir_p(File.join(@products, @frameworks))
    File.binwrite(File.join(@products, @frameworks, 'libconverter_ffi.dylib'), 'fixture converter')
    @source = File.join(@root, 'target/onnxruntime-ios15-src/build/iOS/Release/Release-iphonesimulator/libonnxruntime.1.24.2.dylib')
    @destination = File.join(@products, @frameworks, 'libonnxruntime.1.24.2.dylib')
    @trace = File.join(@root, 'tool trace')
    tool('otool', <<~SH)
      if [ "${FIXTURE_INSPECTION_FAIL:-0}" = 1 ]; then exit 42; fi
      printf '%s:\\n' "$2"
      if [ "$1" = -l ]; then printf 'minos 12.0\\n'; exit 0; fi
      if [ "$1" = -D ]; then
        if [ "${FIXTURE_FAIL_STAGE:-}" = inspect ]; then exit 46; fi
        if [ "${FIXTURE_EMPTY_ID:-0}" != 1 ]; then
          printf '%s\\n' "${FIXTURE_INSTALL_ID:-@rpath/libonnxruntime.1.24.2.dylib}"
        fi
        exit 0
      fi
      if [ "${FIXTURE_STATIC:-0}" != 1 ]; then
        printf '\\t@rpath/libonnxruntime.1.24.2.dylib (compatibility version 0.0.0, current version 1.24.2)\\n'
      fi
    SH
    # Reproduce an unavailable optional search tool regardless of the CI image.
    tool('rg', 'exit 127')
    tool('install_name_tool', <<~SH)
      printf "install:%s:%s:%s\\n" "$1" "$2" "$3" >> "$FIXTURE_TRACE"
      if [ "${FIXTURE_FAIL_STAGE:-}" = install ]; then exit 44; fi
    SH
    tool('codesign', <<~SH)
      printf "sign:%s:%s:%s:%s\\n" "$1" "$2" "${3-}" "${4-}" >> "$FIXTURE_TRACE"
      case "$1" in
        --force) stage=sign ;;
        --verify) stage=verify ;;
        *) exit 45 ;;
      esac
      if [ "${FIXTURE_FAIL_STAGE:-}" = "$stage" ]; then exit 43; fi
    SH
    tool('xcrun', 'exec "$@"')
    tool('mise', <<~SH)
      shift 2
      if [ "$2" = - ]; then exec "$@"; fi
      printf '%s\\n' "$FIXTURE_RUNTIME_DIR"
    SH
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def tool(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod(0o755, path)
  end

  def bundle(extra = {})
    Open3.capture3({
      'PATH' => "#{@bin}:/usr/bin:/bin",
      'PLATFORM_NAME' => 'iphonesimulator',
      'TARGET_BUILD_DIR' => @products,
      'FRAMEWORKS_FOLDER_PATH' => @frameworks,
      'EXPANDED_CODE_SIGN_IDENTITY' => '-',
      'FIXTURE_TRACE' => @trace,
      'FIXTURE_RUNTIME_DIR' => File.dirname(@source),
      'FIXTURE_STATIC' => '0',
      'FIXTURE_INSPECTION_FAIL' => '0'
    }.merge(extra), '/bin/bash', @script)
  end

  def test_dynamic_runtime_is_copied_and_signed_with_paths_containing_spaces
    FileUtils.mkdir_p(File.dirname(@source))
    File.binwrite(@source, "original runtime\0bytes")
    stdout, stderr, status = bundle
    assert status.success?, "#{stdout}\n#{stderr}"
    assert_equal File.binread(@source), File.binread(@destination)
    trace = File.read(@trace)
    refute_includes trace, 'install:'
    assert_includes trace, 'sign:--force:--sign:-:'
    assert_includes trace, "sign:--verify:--strict:#{@destination}:"
  end

  def test_static_runtime_does_not_require_an_external_library
    _, stderr, status = bundle('FIXTURE_STATIC' => '1')
    assert status.success?, stderr
    refute File.exist?(@destination)
    refute File.exist?(@trace)
  end

  def test_failed_dependency_inspection_cannot_be_treated_as_a_static_build
    _, stderr, status = bundle('FIXTURE_INSPECTION_FAIL' => '1')
    refute status.success?
    assert_includes stderr, 'cannot inspect linked ONNX Runtime dependencies'
    refute File.exist?(@destination)
    refute File.exist?(@trace)
  end

  def test_missing_required_dynamic_library_fails_before_signing
    _, stderr, status = bundle
    refute status.success?
    assert_includes stderr, 'missing linked ONNX Runtime'
    refute File.exist?(@destination)
    refute File.exist?(@trace)
  end

  def expected_steps
    ["install:-id:@rpath/libonnxruntime.1.24.2.dylib:#{@destination}",
     "sign:--force:--sign:-:#{@destination}",
     "sign:--verify:--strict:#{@destination}:"]
  end

  def test_matching_install_name_is_not_rewritten_and_source_is_preserved
    FileUtils.mkdir_p(File.dirname(@source))
    original = "vendor runtime\0signature"
    File.binwrite(@source, original)
    _, stderr, status = bundle
    assert status.success?, stderr
    assert_equal expected_steps.drop(1), File.readlines(@trace, chomp: true)
    assert_equal original, File.binread(@source)
  end

  %w[install sign verify].each_with_index do |stage, index|
    define_method("test_failed_#{stage}_stops_packaging_before_later_stages") do
      FileUtils.mkdir_p(File.dirname(@source))
      File.binwrite(@source, 'original vendor runtime')
      _, _, status = bundle('FIXTURE_FAIL_STAGE' => stage, 'FIXTURE_INSTALL_ID' => '@rpath/original.dylib')
      refute status.success?
      assert_equal(stage == 'install' ? 44 : 43, status.exitstatus)
      assert_equal expected_steps.take(index + 1), File.readlines(@trace, chomp: true)
      assert_equal 'original vendor runtime', File.binread(@source)
    end
  end

  def test_different_install_name_is_rewritten_before_signing_only_the_copy
    FileUtils.mkdir_p(File.dirname(@source))
    File.binwrite(@source, 'original vendor runtime')
    _, stderr, status = bundle('FIXTURE_INSTALL_ID' => '@rpath/original.dylib')
    assert status.success?, stderr
    assert_equal expected_steps, File.readlines(@trace, chomp: true)
    assert_equal 'original vendor runtime', File.binread(@source)
  end

  def test_missing_ambiguous_or_unreadable_install_name_prevents_signing
    FileUtils.mkdir_p(File.dirname(@source))
    File.binwrite(@source, 'original vendor runtime')
    [{ 'FIXTURE_EMPTY_ID' => '1' }, { 'FIXTURE_FAIL_STAGE' => 'inspect' },
     { 'FIXTURE_INSTALL_ID' => "@rpath/one.dylib\n@rpath/two.dylib" }].each do |extra|
      _, stderr, status = bundle(extra)
      refute status.success?
      assert_match(/cannot inspect|missing or ambiguous/, stderr)
      refute File.exist?(@trace)
    end
  end

  def test_macos_runtime_with_matching_install_name_is_not_mutated
    FileUtils.mkdir_p(File.dirname(@source))
    File.binwrite(@source, 'original macOS runtime')
    FileUtils.ln_s(File.basename(@source), File.join(File.dirname(@source), 'libonnxruntime.dylib'))
    _, stderr, status = bundle('PLATFORM_NAME' => 'macosx', 'ARCHS' => 'x86_64')
    assert status.success?, stderr
    assert_equal expected_steps.drop(1), File.readlines(@trace, chomp: true)
    assert_equal 'original macOS runtime', File.binread(@source)
  end
end
