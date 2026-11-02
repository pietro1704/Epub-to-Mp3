require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require_relative 'package_ios_validation_archive'

class IOSValidationArchiveTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('ios-validation-archive-')
    @root = File.join(@directory, 'repo')
    @package = File.join(@directory, 'package')
    FileUtils.mkdir_p([@root, @package])
    command('git', 'init', '-q', @root)
    File.write(File.join(@root, 'Cargo.toml'), '[workspace]')
    @app_source = File.join(@root, 'ios/EpubToMp3/EpubToMp3/Application.swift')
    FileUtils.mkdir_p(File.dirname(@app_source))
    File.write(@app_source, 'application fixture')
    command('git', '-C', @root, 'add', '.')
    command('git', '-C', @root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
    @identity = IOSValidationArchive.identity(@root)
    @payload = File.join(@package, 'EpubToMp3.xcarchive.zip')
    File.write(@payload, 'receipt integrity fixture, not a native archive')
    @provenance = { 'source_sha' => command('git', '-C', @root, 'rev-parse', 'HEAD').strip,
      'repository' => 'fixture/repo', 'run_id' => '42', 'run_attempt' => '1',
      'workflow' => 'converter-ffi-ios-prebuilt.yml', 'mode' => 'build_app_only' }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def command(*argv)
    ConverterFfiIOSPackage.command(*argv)
  end

  def package_receipt
    IOSValidationArchive.write_receipt(@root, @package, @identity, provenance: @provenance)
  end

  def test_receipt_reuse_preserves_payload_and_identity
    expected = package_receipt
    before = [File.binread(@payload), File.mtime(@payload)]
    2.times { assert_equal expected, IOSValidationArchive.verify(@root, @package) }
    assert_equal before, [File.binread(@payload), File.mtime(@payload)]
  end

  def test_application_source_changed_during_build_rejects_packaging
    File.write(@app_source, 'changed application')
    assert_match(/Sources changed/, assert_raises(RuntimeError) { package_receipt }.message)
    refute File.exist?(File.join(@package, 'receipt.json'))
  end

  def test_untracked_application_input_cannot_escape_the_receipt
    File.write(File.join(File.dirname(@app_source), 'Untracked.swift'), 'untracked source')
    assert_match(/Untracked build inputs/, assert_raises(RuntimeError) { package_receipt }.message)
    refute File.exist?(File.join(@package, 'receipt.json'))
  end

  def test_mutated_archive_is_rejected_without_removing_evidence
    package_receipt
    File.write(@payload, 'corrupt')
    assert_match(/Archive mismatch/, assert_raises(RuntimeError) { IOSValidationArchive.verify(@root, @package) }.message)
    assert_equal 'corrupt', File.read(@payload)
  end

  def test_checkout_identity_is_not_inferred_from_matching_source_hashes
    package_receipt
    receipt_path = File.join(@package, 'receipt.json')
    receipt = JSON.parse(File.read(receipt_path)).merge('source_sha' => 'a' * 40)
    File.write(receipt_path, JSON.generate(receipt))
    assert_match(/checkout identity/, assert_raises(RuntimeError) { IOSValidationArchive.verify(@root, @package) }.message)
  end

  def test_symlinked_archive_and_receipt_are_rejected
    package_receipt
    File.rename(@payload, @payload + '.original')
    File.symlink(@payload + '.original', @payload)
    assert_raises(RuntimeError) { IOSValidationArchive.verify(@root, @package) }
    File.unlink(@payload)
    File.rename(@payload + '.original', @payload)
    path = File.join(@package, 'receipt.json')
    File.rename(path, path + '.original')
    File.symlink(path + '.original', path)
    assert_raises(RuntimeError) { IOSValidationArchive.verify(@root, @package) }
  end

  def test_workflow_mode_is_explicit_build_only_and_cannot_publish_or_replace_runtime_producer
    workflow = YAML.load_file(File.expand_path('../.github/workflows/converter-ffi-ios-prebuilt.yml', __dir__))
    dispatch = workflow.fetch('on', workflow[true]).fetch('workflow_dispatch')
    assert_equal false, dispatch.fetch('inputs').fetch('build_app_only').fetch('default')
    assert_equal({ 'contents' => 'read' }, workflow.fetch('permissions'))
    producer = workflow.fetch('jobs').fetch('build')
    assert_equal '${{ !inputs.build_app_only }}', producer.fetch('if')
    assert_includes producer.fetch('steps').first.fetch('run'), 'test "$GITHUB_REF" = refs/heads/master'
    job = workflow.fetch('jobs').fetch('validation-app')
    assert_equal '${{ inputs.build_app_only }}', job.fetch('if')
    archive = job.fetch('steps').find { |step| step['name'] == 'Archive the application without signing or launching devices' }
    assert_includes archive.fetch('run'), 'scripts/native_job.rb build'
    assert_includes archive.fetch('run'), 'CODE_SIGNING_ALLOWED=NO'
    assert_includes archive.fetch('run'), '-jobs 1'
    upload = job.fetch('steps').last
    assert_equal 'ios-device-validation-app-v1', upload.fetch('with').fetch('name')
    refute upload.key?('if'), 'A failed or cancelled build must not upload a reusable archive'
    refute_match(/secrets\.|upload-testflight|allowProvisioningUpdates|simctl boot/, JSON.generate(job))
  end
end
