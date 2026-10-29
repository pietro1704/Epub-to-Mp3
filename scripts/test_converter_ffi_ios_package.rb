require 'minitest/autorun'
require 'tmpdir'
require_relative 'package_converter_ffi_ios'

class ConverterFfiIOSPackageTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('ios-package-test-')
    @root = File.join(@directory, 'repo')
    @package = File.join(@directory, 'package')
    FileUtils.mkdir_p([@root, File.join(@package, 'espeak-ng-data')])
    command('git', 'init', '-q', @root)
    File.write(File.join(@root, 'Cargo.toml'), '[workspace]')
    command('git', '-C', @root, 'add', 'Cargo.toml')
    %w[libconverter_ffi.dylib espeak-ng-data/phondata espeak-ng-data/phontab].each do |path|
      File.write(File.join(@package, path), "fixture #{path}")
    end
    @receipt = {
      'schema' => 1, 'target' => 'aarch64-apple-ios', 'profile' => 'release', 'features' => ['piper-runtime'],
      'sources' => ConverterFfiIOSPackage.sources(@root), 'source_sha' => 'a' * 40,
      'workflow' => 'converter-ffi-ios-prebuilt.yml', 'run_id' => '42', 'sdk' => '18.5', 'xcode' => "Xcode 16.4\nBuild version 16F6\n",
      'files' => ConverterFfiMacOSPackage.file_digests(@package)
    }
    write_receipt
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def command(*argv)
    ConverterFfiIOSPackage.command(*argv)
  end

  def write_receipt
    File.write(File.join(@package, 'receipt.json'), JSON.generate(@receipt))
  end

  def verify
    ConverterFfiIOSPackage.verify(@root, @package, native: false)
  end

  def test_verified_reuse_preserves_bytes_and_mtime
    library = File.join(@package, 'libconverter_ffi.dylib')
    before = [File.binread(library), File.mtime(library)]
    2.times { assert_equal @receipt, verify }
    assert_equal before, [File.binread(library), File.mtime(library)]
  end

  def test_source_change_rejects_old_package
    File.write(File.join(@root, 'Cargo.toml'), '[changed]')
    assert_match(/Source mismatch/, assert_raises(RuntimeError) { verify }.message)
  end

  def test_corrupt_library_is_rejected_and_preserved
    library = File.join(@package, 'libconverter_ffi.dylib')
    File.write(library, 'corrupt')
    assert_match(/Payload mismatch/, assert_raises(RuntimeError) { verify }.message)
    assert_equal 'corrupt', File.read(library)
  end

  def test_wrong_platform_and_toolchain_are_rejected
    @receipt['target'] = 'x86_64-apple-darwin'
    write_receipt
    assert_raises(RuntimeError) { verify }
    @receipt['target'] = 'aarch64-apple-ios'
    @receipt['xcode'] = "Xcode 26.0\n"
    write_receipt
    assert_raises(RuntimeError) { verify }
  end

  def test_symlink_payload_is_rejected
    File.symlink(File.join(@root, 'Cargo.toml'), File.join(@package, 'espeak-ng-data/escape'))
    assert_match(/symlink/, assert_raises(RuntimeError) { verify }.message)
  end

  def test_missing_payload_is_rejected
    File.unlink(File.join(@package, 'espeak-ng-data/phontab'))
    assert_raises(RuntimeError) { verify }
  end

  def test_non_hosted_package_request_cannot_create_output
    output = File.join(@directory, 'new-output')
    assert_raises(RuntimeError) { ConverterFfiIOSPackage.package(@root, output) }
    refute File.exist?(output)
  end
end
