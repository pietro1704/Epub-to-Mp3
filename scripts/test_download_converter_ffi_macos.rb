#!/usr/bin/env ruby
require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'download_converter_ffi_macos'

class ConverterFfiMacOSDownloaderTest < Minitest::Test
  Downloader = ConverterFfiMacOSDownloader
  RUN_ID = '123456789'
  ATTEMPT = '2'
  SOURCE_SHA = 'a' * 40
  IDENTITY = {
    'schema_version' => 1,
    'platform' => 'macos',
    'architecture' => 'x86_64',
    'rust_target' => 'x86_64-apple-darwin',
    'features' => ['piper-runtime'],
    'profile' => 'release',
    'source_files' => { 'Cargo.lock' => 'b' * 64 }
  }.freeze

  class Client
    attr_reader :run, :artifact, :archive_bytes

    def initialize(run:, artifact:, archive_bytes:)
      @run = run
      @artifact = artifact
      @archive_bytes = archive_bytes
    end

    def json(path)
      return run if path.end_with?("/runs/#{RUN_ID}")
      return { 'total_count' => 1, 'artifacts' => [artifact] } if path.end_with?("/runs/#{RUN_ID}/artifacts?per_page=100")
      raise "Unexpected API path: #{path}"
    end

    def archive(path, destination)
      raise "Unexpected archive path: #{path}" unless path.end_with?('/artifacts/456/zip')
      File.binwrite(destination, archive_bytes)
      destination
    end
  end

  def setup
    @temporary = Dir.mktmpdir('ffi-downloader-test-')
    @root = File.join(@temporary, 'repo')
    FileUtils.mkdir_p(@root)
    @package = File.join(@temporary, 'payload')
    FileUtils.mkdir_p(File.join(@package, 'espeak-ng-data'))
    File.binwrite(File.join(@package, 'libconverter_ffi.dylib'), 'macho-fixture')
    File.binwrite(File.join(@package, 'espeak-ng-data', 'phontab'), 'phontab-fixture')
    File.binwrite(File.join(@package, 'espeak-ng-data', 'phondata'), 'phondata-fixture')
    @run = {
      'id' => RUN_ID.to_i,
      'run_attempt' => ATTEMPT.to_i,
      'status' => 'completed',
      'conclusion' => 'success',
      'head_branch' => 'master',
      'head_repository' => { 'full_name' => Downloader::REPOSITORY },
      'event' => 'workflow_dispatch',
      'path' => Downloader::WORKFLOW,
      'head_sha' => SOURCE_SHA
    }
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_downloads_only_verified_master_artifact_and_installs_bundle_paths
    client, = client_for(@package)
    verify_calls = []
    Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'fixture-token', client: client,
                        now: Time.utc(2026, 1, 1), verify_package: ->(root, package, sha) { verify_calls << [root, package, sha] })

    assert_equal 'macho-fixture', File.binread(File.join(@root, 'target/release/libconverter_ffi.dylib'))
    data = File.join(@root, 'target/espeak-data', Downloader::DATA_DESTINATION)
    assert_equal 'phontab-fixture', File.binread(File.join(data, 'phontab'))
    assert_equal 'phondata-fixture', File.binread(File.join(data, 'phondata'))
    assert_equal 1, verify_calls.length
    assert_equal @root, verify_calls.first[0]
    assert_equal Digest::SHA256.hexdigest(Downloader.canonical_json(IDENTITY)), verify_calls.first[2]
  end

  def test_rejects_untrusted_run_identity_before_download
    bad_run = @run.merge('head_branch' => 'pull/7/merge')
    client, = client_for(@package, run: bad_run)
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: client,
                          verify_package: ->(*) { flunk 'must reject the run before package verification' })
    end
    refute File.exist?(File.join(@root, 'target'))
  end

  def test_rejects_attempt_mismatch_and_expired_artifact
    client, artifact = client_for(@package)
    bad_run = @run.merge('run_attempt' => 1)
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: Client.new(run: bad_run, artifact: artifact, archive_bytes: client.archive_bytes))
    end
    expired, = client_for(@package, expires_at: '2025-12-31T00:00:00Z')
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: expired,
                          now: Time.utc(2026, 1, 1), verify_package: ->(*) {})
    end
    over_retention, = client_for(@package, expires_at: '2026-04-05T00:00:00Z')
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: over_retention,
                          now: Time.utc(2026, 1, 1), verify_package: ->(*) {})
    end
    refute File.exist?(File.join(@root, 'target'))
  end

  def test_rejects_digest_mismatch_and_preserves_existing_outputs
    client, artifact = client_for(@package)
    bad = Client.new(run: @run, artifact: artifact.merge('digest' => "sha256:#{'0' * 64}"), archive_bytes: client.archive_bytes)
    FileUtils.mkdir_p(File.join(@root, 'target/release'))
    File.binwrite(File.join(@root, 'target/release/libconverter_ffi.dylib'), 'existing')
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: bad,
                          verify_package: ->(*) {})
    end
    assert_equal 'existing', File.binread(File.join(@root, 'target/release/libconverter_ffi.dylib'))
  end

  def test_rejects_receipt_identity_mismatch_without_installing_partial_outputs
    client, = client_for(@package, receipt_data: receipt(identity_sha: '0' * 64))
    assert_raises(RuntimeError) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: client,
                          verify_package: ->(*) { flunk 'must reject receipt before verifier' })
    end
    refute File.exist?(File.join(@root, 'target'))
  end

  def test_receipt_package_is_accepted_by_the_real_producer_verifier
    repository_root = ENV.fetch('CONVERTER_FFI_PRODUCER_ROOT', File.expand_path('..', __dir__))
    helper = File.join(repository_root, 'scripts/package_converter_ffi_macos.rb')
    raise 'Producer verifier must be present for downloader contract tests' unless File.file?(helper)
    require helper

    source_sha = IO.popen(['git', '-C', repository_root, 'rev-parse', 'HEAD'], &:read).strip
    identity = ConverterFfiMacOSPackage.identity(repository_root)
    producer = {
      'workflow' => Downloader::ARTIFACT_WORKFLOW,
      'event' => 'workflow_dispatch',
      'ref' => 'refs/heads/master',
      'run_id' => RUN_ID,
      'run_attempt' => ATTEMPT
    }
    toolchain = { 'rustc' => 'rustc 1.86.0', 'xcode' => 'Xcode 16.4 Build version 16F6', 'macos_sdk' => '15.5' }
    fixture = receipt(identity: identity, source_sha: source_sha, producer: producer).merge('toolchain' => toolchain)
    run = @run.merge('head_sha' => source_sha)
    client, = client_for(@package, run: run, receipt_data: fixture)
    verify = lambda do |_install_root, package, identity_sha|
      ConverterFfiMacOSPackage.verify(repository_root, package, expected_identity_sha: identity_sha, inspect_native: false)
    end

    Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'fixture-token', client: client,
                        now: Time.utc(2026, 1, 1), verify_package: verify)
    assert_equal 'macho-fixture', File.binread(File.join(@root, 'target/release/libconverter_ffi.dylib'))
  end

  def test_rejects_zip_slip_and_symlink_entries_before_extraction
    zip = zip_for(@package)
    escaped = File.binread(zip).gsub('espeak-ng-data/phontab', 'espeak-ng-data/../xxxx')
    assert_raises(RuntimeError) { Downloader.zip_entries(write_zip('traversal.zip', escaped)) }

    link = File.join(@package, 'espeak-ng-data', 'linked')
    File.symlink('phontab', link)
    symlink_zip = zip_for(@package)
    assert_raises(RuntimeError) { Downloader.zip_entries(symlink_zip) }
  ensure
    FileUtils.rm_f(link) if link
  end

  def test_cancellation_leaves_no_installable_partial_package
    client, = client_for(@package)
    client.define_singleton_method(:archive) { |_path, _destination| raise Interrupt }
    assert_raises(Interrupt) do
      Downloader.download(root: @root, run_id: RUN_ID, run_attempt: ATTEMPT, token: 'token', client: client,
                          now: Time.utc(2026, 1, 1), verify_package: ->(*) {})
    end
    refute File.exist?(File.join(@root, 'target'))
  end

  def test_install_refuses_preexisting_backup_without_touching_current_outputs
    target = File.join(@root, 'target')
    library = File.join(target, 'release/libconverter_ffi.dylib')
    data = File.join(target, 'espeak-data', Downloader::DATA_DESTINATION)
    backup_library = "#{library}.prebuilt-previous"
    FileUtils.mkdir_p(File.dirname(library))
    FileUtils.mkdir_p(data)
    File.binwrite(library, 'current-library')
    File.binwrite(backup_library, 'older-library-backup')
    File.binwrite(File.join(data, 'phontab'), 'current-phontab')
    File.binwrite(File.join(data, 'phondata'), 'current-phondata')

    assert_raises(RuntimeError) { Downloader.install_package(@root, @package) }
    assert_equal 'current-library', File.binread(library)
    assert_equal 'older-library-backup', File.binread(backup_library)
    assert_equal 'current-phontab', File.binread(File.join(data, 'phontab'))
  end

  def test_install_rolls_back_both_outputs_when_cancelled_midway
    target = File.join(@root, 'target')
    library = File.join(target, 'release/libconverter_ffi.dylib')
    data = File.join(target, 'espeak-data', Downloader::DATA_DESTINATION)
    FileUtils.mkdir_p(File.dirname(library))
    FileUtils.mkdir_p(data)
    File.binwrite(library, 'current-library')
    File.binwrite(File.join(data, 'phontab'), 'current-phontab')
    File.binwrite(File.join(data, 'phondata'), 'current-phondata')
    original_rename = File.method(:rename)
    rename_count = 0
    cancellable_rename = lambda do |source, destination|
      rename_count += 1
      raise Interrupt, 'cancel during second artifact install' if rename_count == 4
      original_rename.call(source, destination)
    end

    assert_raises(Interrupt) { Downloader.install_package(@root, @package, rename: cancellable_rename) }
    assert_equal 'current-library', File.binread(library)
    assert_equal 'current-phontab', File.binread(File.join(data, 'phontab'))
    assert_equal 'current-phondata', File.binread(File.join(data, 'phondata'))
    refute File.exist?("#{library}.prebuilt-previous")
    refute File.exist?("#{data}.prebuilt-previous")
  end

  def test_faber_prebuilt_is_opt_in_and_disables_all_intel_rust_build_cache_paths
    workflow = File.read(File.join(__dir__, '..', '.github/workflows/faber-integration.yml'))
    assert_equal 2, workflow.scan(/intel_prebuilt:\n\s+description:.*\n\s+type: boolean\n\s+default: false/).length
    assert_includes workflow, "if: matrix.arch == 'x86_64' && inputs.intel_prebuilt"
    assert_includes workflow, "if: matrix.arch == 'x86_64' && !inputs.intel_prebuilt"
    assert_includes workflow, "if: matrix.arch != 'x86_64' || !inputs.intel_prebuilt"
    assert_includes workflow, "matrix.arch == 'x86_64' && inputs.intel_prebuilt && 'python'"
    assert_match(/Download and verify the pinned Intel converter-ffi artifact.*?mise run onnxruntime:host.*?scripts\/download_converter_ffi_macos\.rb/m, workflow)
    assert_match(/Verify actual FFI and pinned ORT architectures.*?xcrun lipo -archs target\/release\/libconverter_ffi\.dylib/m, workflow)
  end

  private

  def receipt(identity_sha: nil, identity: IDENTITY, source_sha: SOURCE_SHA, producer: nil)
    payload_files = Dir.glob(File.join(@package, '**', '*')).select { |path| File.file?(path) && File.basename(path) != 'receipt.json' }
    files = payload_files.to_h { |path| [path.delete_prefix("#{@package}/"), Digest::SHA256.file(path).hexdigest] }.sort.to_h
    producer ||= {
      'workflow' => Downloader::ARTIFACT_WORKFLOW,
      'event' => 'workflow_dispatch',
      'ref' => 'refs/heads/master',
      'run_id' => RUN_ID,
      'run_attempt' => ATTEMPT
    }
    {
      'schema_version' => 1,
      'identity' => identity,
      'identity_sha256' => identity_sha || Digest::SHA256.hexdigest(Downloader.canonical_json(identity)),
      'source_sha' => source_sha,
      'producer' => producer,
      'files' => files
    }
  end

  def client_for(package, run: @run, expires_at: '2026-03-31T00:00:00Z', receipt_data: nil)
    File.write(File.join(package, 'receipt.json'), JSON.generate(receipt_data || receipt))
    zip = zip_for(package)
    bytes = File.binread(zip)
    artifact = {
      'id' => 456,
      'name' => Downloader::ARTIFACT_NAME,
      'expired' => false,
      'expires_at' => expires_at,
      'size_in_bytes' => bytes.bytesize,
      'created_at' => '2026-01-01T00:00:00Z',
      'digest' => "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    }
    [Client.new(run: run, artifact: artifact, archive_bytes: bytes), artifact]
  end

  def zip_for(package, recurse: false)
    path = File.join(@temporary, "fixture-#{rand(1_000_000)}.zip")
    arguments = ['zip', '-q', '-y', path, 'libconverter_ffi.dylib', 'receipt.json', 'espeak-ng-data/phontab', 'espeak-ng-data/phondata']
    arguments.insert(1, '-r') if recurse
    arguments << 'espeak-ng-data/linked' if File.symlink?(File.join(package, 'espeak-ng-data', 'linked'))
    system(*arguments, chdir: package) || raise('zip fixture creation failed')
    path
  end

  def write_zip(name, bytes)
    path = File.join(@temporary, name)
    File.binwrite(path, bytes)
    path
  end
end
