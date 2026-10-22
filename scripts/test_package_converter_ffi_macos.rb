require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative 'package_converter_ffi_macos'

class PackageConverterFfiMacOSTest < Minitest::Test
  TOOLCHAIN = { 'rustc' => 'rustc fixture', 'xcode' => 'Xcode 16.4 Build version fixture', 'macos_sdk' => '15.5' }.freeze
  WORKFLOW = File.expand_path('../.github/workflows/converter-ffi-macos-intel-prebuilt.yml', __dir__)
  def setup
    @tmp = Dir.mktmpdir('converter ffi prebuilt fixture ')
    @root = File.join(@tmp, 'source')
    FileUtils.mkdir_p(File.join(@root, 'scripts'))
    FileUtils.cp(File.join(__dir__, 'package_converter_ffi_macos.rb'), File.join(@root, 'scripts/package_converter_ffi_macos.rb'))
    FileUtils.mkdir_p(File.join(@root, '.github/workflows'))
    File.write(File.join(@root, '.github/workflows/converter-ffi-macos-intel-prebuilt.yml'), 'fixture workflow')
    %w[Cargo.toml Cargo.lock mise.toml].each { |name| File.write(File.join(@root, name), "fixture #{name}\n") }
    git('init', '-q')
    git('add', '.')
    git('config', 'user.email', 'fixture@example.invalid')
    git('config', 'user.name', 'Fixture')
    git('commit', '-qm', 'fixture source')
    @source_sha = git('rev-parse', 'HEAD').strip
    FileUtils.mkdir_p(File.join(@root, 'target/x86_64-apple-darwin/release'))
    File.binwrite(File.join(@root, 'target/x86_64-apple-darwin/release/libconverter_ffi.dylib'), "fixture dylib\0bytes")
    data = File.join(@root, 'target/espeak-data/build/out/build/espeak-ng-data')
    FileUtils.mkdir_p(data)
    File.write(File.join(data, 'phontab'), 'phoneme table')
    File.write(File.join(data, 'phondata'), 'phoneme data')
    @package = File.join(@tmp, 'package')
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def git(*args)
    output, status = Open3.capture2e('git', '-C', @root, *args)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end

  def package!
    ConverterFfiMacOSPackage.package(@root, @package, @source_sha, '123456', '2', toolchain: TOOLCHAIN, inspect_native: false)
  end

  def verify!
    ConverterFfiMacOSPackage.verify(@root, @package, inspect_native: false)
  end

  def test_packages_and_verifies_exact_payload_with_receipt
    assert_equal @package, package!
    assert_equal @package, verify!
    receipt = JSON.parse(File.read(File.join(@package, 'receipt.json')))
    assert_equal @source_sha, receipt.fetch('source_sha')
    assert_equal '123456', receipt.dig('producer', 'run_id')
    assert_equal '2', receipt.dig('producer', 'run_attempt')
    assert_equal %w[espeak-ng-data/phondata espeak-ng-data/phontab libconverter_ffi.dylib].sort, receipt.fetch('files').keys.sort
  end

  def test_rejects_changed_build_inputs
    package!
    File.write(File.join(@root, 'Cargo.toml'), 'changed after producer build')
    error = assert_raises(RuntimeError) { verify! }
    assert_includes error.message, 'source/build recipe mismatch'
  end

  def test_rejects_payload_hash_mismatch
    package!
    File.binwrite(File.join(@package, 'libconverter_ffi.dylib'), 'tampered')
    error = assert_raises(RuntimeError) { verify! }
    assert_includes error.message, 'file hashes mismatch'
  end

  def test_rejects_unexpected_paths
    package!
    File.write(File.join(@package, 'unlisted.txt'), 'unexpected')
    error = assert_raises(RuntimeError) { verify! }
    assert_includes error.message, 'unexpected files'
  end

  def test_rejects_symlinked_payload_paths
    package!
    File.symlink('/etc/hosts', File.join(@package, 'espeak-ng-data', 'host-link'))
    error = assert_raises(RuntimeError) { verify! }
    assert_includes error.message, 'symlink'
  end

  def test_rejects_wrong_expected_identity
    package!
    error = assert_raises(RuntimeError) do
      ConverterFfiMacOSPackage.verify(@root, @package, expected_identity_sha: '0' * 64, inspect_native: false)
    end
    assert_includes error.message, 'Unexpected build identity'
  end

  def test_preserves_an_existing_output_directory
    FileUtils.mkdir_p(@package)
    sentinel = File.join(@package, 'keep.txt')
    File.write(sentinel, 'preserve')
    error = assert_raises(RuntimeError) do
      ConverterFfiMacOSPackage.package(@root, @package, @source_sha, '123456', '2', toolchain: TOOLCHAIN, inspect_native: false)
    end
    assert_includes error.message, 'must not exist'
    assert_equal 'preserve', File.read(sentinel)
  end

  def test_rejects_uncommitted_build_inputs_before_packaging
    File.write(File.join(@root, 'Cargo.toml'), 'uncommitted change')
    error = assert_raises(RuntimeError) do
      ConverterFfiMacOSPackage.package(@root, @package, @source_sha, '123456', '2', toolchain: TOOLCHAIN, inspect_native: false)
    end
    assert_includes error.message, 'Build inputs differ from the checked out commit'
    refute File.exist?(@package)
  end

  def test_workflow_is_manual_intel_master_only_and_uploads_verified_receipt
    workflow = File.read(WORKFLOW)
    assert_match(/^on:\n  workflow_dispatch:\s*$/m, workflow)
    refute_match(/^  pull_request:/, workflow)
    assert_includes workflow, 'runs-on: macos-15-intel'
    assert_includes workflow, "test \"$GITHUB_REF\" = refs/heads/master"
    assert_includes workflow, "test \"$(xcodebuild -version | head -n 1)\" = 'Xcode 16.4'"
    assert_includes workflow, "test \"$(xcrun --sdk macosx --show-sdk-version)\" = '15.5'"
    assert_equal 2, workflow.scan(/^\s+run: ruby scripts\/native_job\.rb build -- cargo build /).length
    assert_includes workflow, 'ruby/setup-ruby@b1da4809b005e0178fe08a1d57317bffc00b7b4c'
    assert_includes workflow, 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
    assert_includes workflow, 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
    assert_includes workflow, 'name: converter-ffi-macos-intel-x86_64-v1'
    assert_includes workflow, 'if-no-files-found: error'
    assert_includes workflow, 'retention-days: 90'
    assert_includes workflow, 'ruby scripts/package_converter_ffi_macos.rb package'
  end
end
