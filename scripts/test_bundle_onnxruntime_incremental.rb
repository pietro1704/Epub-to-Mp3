# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'

class OnnxIncrementalPackagingTest < Minitest::Test
  ROOT = File.expand_path(ENV.fetch('ONNX_TEST_ROOT', File.expand_path('..', __dir__)))
  SCRIPT = ENV.fetch('ONNX_BUNDLER_UNDER_TEST', File.join(ROOT, 'scripts/bundle_onnxruntime_apple.sh'))

  def setup
    skip 'Real macOS packaging test requires macOS' unless RUBY_PLATFORM.include?('darwin')
    @runtime = File.join(ROOT, 'target/onnxruntime-macos-prebuilt/x86_64')
    @ffi = File.join(ROOT, 'target/release/libconverter_ffi.dylib')
    skip 'Verified Intel FFI/ONNX artifacts are required; this test never builds or downloads them' unless File.file?(@ffi) && File.file?(File.join(@runtime, 'runtime.json'))
    @original_hashes = [@ffi, File.join(@runtime, 'lib/libonnxruntime.dylib')].to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }
    @temporary = Dir.mktmpdir('onnx packaging with spaces ')
    @fixture = File.join(@temporary, 'checkout')
    scripts = File.join(@fixture, 'scripts')
    FileUtils.mkdir_p([scripts, File.join(@fixture, 'target/onnxruntime-macos-prebuilt')])
    %w[prepare_onnxruntime_macos.rb fetch_onnxruntime_macos.rb native_job.rb native_build_preflight.rb mac_build_budget.rb].each do |name|
      FileUtils.cp(File.join(ROOT, 'scripts', name), scripts)
    end
    @script = File.join(scripts, 'bundle_onnxruntime_apple.sh')
    FileUtils.cp(SCRIPT, @script)
    FileUtils.cp_r(@runtime, File.join(@fixture, 'target/onnxruntime-macos-prebuilt'))
    @build = File.join(@temporary, 'build')
    @frameworks = File.join(@build, 'Fixture.app/Contents/Frameworks')
    FileUtils.mkdir_p(@frameworks)
    FileUtils.cp(@ffi, @frameworks)
    @destination = File.join(@frameworks, 'libonnxruntime.dylib')
    @source = File.join(@fixture, 'target/onnxruntime-macos-prebuilt/x86_64/lib/libonnxruntime.dylib')
    bin = File.join(@temporary, 'bin')
    FileUtils.mkdir_p(bin)
    @trace = File.join(@temporary, 'operations')
    File.write(File.join(bin, 'cp'), <<~SH)
      #!/bin/bash
      printf 'copy\n' >> "$ONNX_TEST_TRACE"
      exec /bin/cp "$@"
    SH
    File.write(File.join(bin, 'codesign'), <<~SH)
      #!/bin/bash
      for argument in "$@"; do
        if [[ "$argument" == --sign ]]; then
          printf 'sign\n' >> "$ONNX_TEST_TRACE"
          [[ "${ONNX_TEST_REJECT_SIGNING:-0}" == 1 ]] && exit 42
        fi
      done
      exec /usr/bin/codesign "$@"
    SH
    FileUtils.chmod(0o755, Dir.glob(File.join(bin, '*')))
    @environment = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'PLATFORM_NAME' => 'macosx', 'ARCHS' => 'x86_64',
      'TARGET_BUILD_DIR' => @build, 'FRAMEWORKS_FOLDER_PATH' => 'Fixture.app/Contents/Frameworks',
      'EXPANDED_CODE_SIGN_IDENTITY' => '-', 'ONNX_TEST_TRACE' => @trace,
      'MISE_AUTO_INSTALL' => 'false', 'MISE_EXEC_AUTO_INSTALL' => 'false'
    }
  end

  def teardown
    @original_hashes&.each { |path, digest| assert_equal digest, Digest::SHA256.file(path).hexdigest, 'Original artifact changed' }
    FileUtils.remove_entry(@temporary) if @temporary && File.directory?(@temporary)
  end

  def bundle(extra = {})
    Open3.capture3(@environment.merge(extra), '/bin/bash', @script, chdir: ROOT)
  end

  def bundle_success
    output, error, status = bundle
    assert status.success?, "#{output}\n#{error}"
    output
  end

  def operations
    File.exist?(@trace) ? File.read(@trace).lines.map(&:strip) : []
  end

  def assert_valid_signature
    _output, error, status = Open3.capture3('/usr/bin/codesign', '--verify', '--strict', @destination)
    assert status.success?, error
  end

  def test_unchanged_verified_runtime_preserves_file_and_skips_copy_and_sign
    bundle_success
    assert_equal %w[copy sign], operations
    sentinel = Time.at(1_600_000_000)
    File.utime(sentinel, sentinel, @destination)
    inode = File.stat(@destination).ino
    output = bundle_success
    assert_equal %w[copy sign], operations, 'Unchanged runtime must not be copied or re-signed'
    assert_equal sentinel, File.mtime(@destination)
    assert_equal inode, File.stat(@destination).ino
    assert_includes output, 'preserved verified ad-hoc signature'
    assert_valid_signature
  end

  def test_corrupted_destination_is_replaced_and_verified
    bundle_success
    File.open(@destination, 'r+b') { |file| file.seek(4096); value = file.read(1).getbyte(0); file.seek(4096); file.write((value ^ 1).chr) }
    bundle_success
    assert_equal %w[copy sign copy sign], operations
    assert_equal Digest::SHA256.file(@source).hexdigest, Digest::SHA256.file(@destination).hexdigest
    assert_valid_signature
  end

  def test_missing_destination_is_recreated
    bundle_success
    File.unlink(@destination)
    bundle_success
    assert_equal %w[copy sign copy sign], operations
    assert_valid_signature
  end

  def test_changed_source_fails_verification_before_touching_destination
    bundle_success
    before = Digest::SHA256.file(@destination).hexdigest
    File.open(@source, 'ab') { |file| file.write('invalid source') }
    _output, error, status = bundle
    refute status.success?
    assert_includes error, 'checksum mismatch'
    assert_equal %w[copy sign], operations
    assert_equal before, Digest::SHA256.file(@destination).hexdigest
  end

  def test_certificate_signing_request_does_not_take_ad_hoc_shortcut
    bundle_success
    _output, _error, status = bundle('EXPANDED_CODE_SIGN_IDENTITY' => 'fixture-certificate', 'ONNX_TEST_REJECT_SIGNING' => '1')
    assert_equal 42, status.exitstatus
    assert_equal %w[copy sign copy sign], operations
  end
end
