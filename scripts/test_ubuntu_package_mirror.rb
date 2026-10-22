# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'yaml'

class UbuntuPackageMirrorTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HELPER = File.join(ROOT, 'scripts/normalize_ubuntu_package_mirror.rb')
  AZURE = 'http://azure.archive.ubuntu.com/ubuntu/'
  OFFICIAL = 'https://archive.ubuntu.com/ubuntu/'

  def setup
    @root = Dir.mktmpdir('apt sources fixture ')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def source(name, bytes)
    path = File.join(@root, name)
    File.binwrite(path, bytes)
    path
  end

  def invoke(*paths)
    Open3.capture3(RbConfig.ruby, HELPER, *paths)
  end

  def test_direct_deb822_source_preserves_signed_by_suites_and_permissions
    original = "Types: deb\nURIs: #{AZURE}\nSuites: noble noble-updates\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
    path = source('ubuntu.sources', original)
    File.chmod(0o640, path)
    out, err, status = invoke(path)
    assert status.success?, err
    assert_equal original.sub(AZURE, OFFICIAL), File.binread(path)
    assert_equal 0o640, File.stat(path).mode & 0o777
    assert_includes out, 'updated=1'
    out, err, status = invoke(path)
    assert status.success?, err
    assert_includes out, 'updated=0'
    assert_equal original.sub(AZURE, OFFICIAL), File.binread(path)
  end

  def test_mirror_file_is_normalized_without_changing_mirror_plus_file_or_other_mirrors
    sources = "URIs: mirror+file:/etc/apt/apt-mirrors.txt\nSigned-By: /keyring.gpg\n"
    config = source('ubuntu.sources', sources)
    original = "# runner mirrors\n#{AZURE}\nhttps://security.ubuntu.com/ubuntu/ priority:2\n"
    mirrors = source('apt-mirrors.txt', original)
    _out, err, status = invoke(config, mirrors)
    assert status.success?, err
    assert_equal sources, File.binread(config)
    assert_equal original.sub(AZURE, OFFICIAL), File.binread(mirrors)
  end

  def test_legacy_source_and_https_azure_are_supported
    original = 'deb [signed-by=/keyring.gpg] https://azure.archive.ubuntu.com/ubuntu noble main'
    path = source('sources.list', original)
    _out, err, status = invoke(path)
    assert status.success?, err
    assert_equal original.sub('https://azure.archive.ubuntu.com/ubuntu', OFFICIAL.delete_suffix('/')), File.binread(path)
  end

  def test_official_sources_are_idempotent_and_comments_and_unrelated_hosts_remain_identical
    original = "# #{AZURE}\nURIs: #{OFFICIAL} https://example.invalid/ubuntu/\n"
    path = source('ubuntu.sources', original)
    2.times do
      out, err, status = invoke(path, File.join(@root, 'optional-missing.sources'))
      assert status.success?, err
      assert_includes out, 'updated=0'
      assert_equal original, File.binread(path)
    end
  end

  def test_missing_source_inventory_fails_explicitly
    _out, err, status = invoke(File.join(@root, 'missing.sources'))
    refute status.success?
    assert_includes err, 'No APT source files found'
  end

  def test_malformed_azure_uri_is_rejected_before_any_source_is_written
    original = "URIs: #{AZURE}\n"
    valid = source('ubuntu.sources', original)
    invalid = source('apt-mirrors.txt', "http://azure.archive.ubuntu.com/other\n")
    _out, err, status = invoke(valid, invalid)
    refute status.success?
    assert_includes err, 'Unsupported Azure archive URI'
    assert_equal original, File.binread(valid)
  end

  def test_cli_bootstrap_bounds_network_wait_without_weakening_apt_validation
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/cli-faber-golden.yml'))
    job = workflow.fetch('jobs').fetch('packaged-cli')
    assert_equal 35, job.fetch('timeout-minutes')
    step = job.fetch('steps').find { |entry| entry['name'] == 'Install native build and full audio decoding prerequisites' }
    assert_equal 7, step.fetch('timeout-minutes')
    run = step.fetch('run')
    assert_includes run, 'scripts/normalize_ubuntu_package_mirror.rb'
    assert_operator run.index('scripts/normalize_ubuntu_package_mirror.rb'), :<, run.index('apt-get')
    %w[Acquire::Retries=2 Acquire::http::Timeout=20 Acquire::https::Timeout=20 APT::Update::Error-Mode=any].each do |option|
      assert_includes run, option
    end
    assert_includes run, 'clang libclang-dev cmake pkg-config ffmpeg unzip binutils'
    refute_match(/allow-unauthenticated|allow-insecure|Verify-Peer=false|trusted=yes/i, run)
  end
end
