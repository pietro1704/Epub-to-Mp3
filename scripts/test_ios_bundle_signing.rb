require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class IosBundleSigningTest < Minitest::Test
  SCRIPT = File.expand_path('bundle_converter_ffi_ios.sh', __dir__)

  def setup
    @root = Dir.mktmpdir('ios signing fixture with spaces ')
    @scripts = File.join(@root, 'scripts')
    @srcroot = File.join(@root, 'ios', 'EpubToMp3')
    @bin = File.join(@root, 'fake signing tools')
    @products = File.join(@root, 'products')
    FileUtils.mkdir_p([@scripts, @srcroot, @bin, @products])
    @script = File.join(@scripts, File.basename(SCRIPT))
    FileUtils.cp(SCRIPT, @script)
    # Native architecture/platform verification remains covered by the real
    # CodeQL build; isolate only the copied artifact's signing policy here.
    File.write(File.join(@scripts, 'verify_converter_ffi_ios.sh'), "#!/bin/sh\nexit 0\n")
    @artifact = File.join(@root, 'target/aarch64-apple-ios/release/libconverter_ffi.dylib')
    FileUtils.mkdir_p(File.dirname(@artifact))
    File.binwrite(@artifact, "owned dylib fixture\0")
    @trace = File.join(@root, 'signing trace')
    signing = File.join(@bin, 'codesign')
    File.write(signing, <<~SH)
      #!/bin/sh
      set -eu
      printf 'global:%s\\n' "${EXPANDED_CODE_SIGN_IDENTITY:-}" >> "$FIXTURE_TRACE"
      for argument in "$@"; do printf '[%s]' "$argument" >> "$FIXTURE_TRACE"; done
      printf '\\n' >> "$FIXTURE_TRACE"
    SH
    File.chmod(0o755, signing)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def bundle(allowed, identity = '')
    Open3.capture3({
      'PATH' => "#{@bin}:/usr/bin:/bin", 'SRCROOT' => @srcroot,
      'PLATFORM_NAME' => 'iphoneos', 'TARGET_BUILD_DIR' => @products,
      'FRAMEWORKS_FOLDER_PATH' => 'Frameworks with spaces',
      'CONVERTER_FFI_BUILD_ALWAYS' => '0', 'FIXTURE_TRACE' => @trace,
      'CODE_SIGNING_ALLOWED' => allowed, 'EXPANDED_CODE_SIGN_IDENTITY' => identity
    }, '/bin/bash', @script)
  end

  def test_unsigned_host_build_signs_only_the_copied_dylib_ad_hoc
    stdout, stderr, status = bundle('NO')
    assert status.success?, "#{stdout}\n#{stderr}"
    destination = File.join(@products, 'Frameworks with spaces/libconverter_ffi.dylib')
    assert_equal File.binread(@artifact), File.binread(destination)
    trace = File.read(@trace)
    assert_includes trace, "[--force][--sign][-][#{destination}]"
    assert_includes trace, "[--verify][--strict][#{destination}]"
    assert_equal 2, trace.lines.count { |line| line == "global:\n" }, 'Local ad hoc signing must not change the host signing setting'
    assert_equal [destination], Dir.glob(File.join(@products, '**', '*')).select { |path| File.file?(path) }
  end

  def test_enabled_signing_without_a_real_identity_still_fails
    _, stderr, status = bundle('YES')
    refute status.success?
    assert_includes stderr, 'missing iOS dylib signing identity'
    refute File.exist?(@trace)
  end

  def test_explicit_signing_identity_is_preserved_for_both_build_modes
    %w[YES NO].each do |allowed|
      FileUtils.rm_f(@trace)
      _, stderr, status = bundle(allowed, 'Explicit Identity With Spaces')
      assert status.success?, stderr
      trace = File.read(@trace)
      assert_includes trace, '[--force][--sign][Explicit Identity With Spaces]'
      assert_includes trace, 'global:Explicit Identity With Spaces'
    end
  end
end
