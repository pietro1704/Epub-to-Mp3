# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class EspeakIncrementalPackagingTest < Minitest::Test
  ROOT = File.expand_path(ENV.fetch('ESPEAK_TEST_ROOT', File.expand_path('..', __dir__)))
  SCRIPT = ENV.fetch('ESPEAK_BUNDLER_UNDER_TEST', File.join(ROOT, 'scripts/bundle_espeak_ng_data.sh'))

  def setup
    skip 'Real ditto packaging requires macOS' unless RUBY_PLATFORM.include?('darwin')
    @temporary = Dir.mktmpdir('espeak packaging with spaces ')
    @source = File.join(@temporary, 'target/espeak-data/release/build/fixture/out/build/espeak-ng-data')
    scripts = File.join(@temporary, 'scripts')
    bin = File.join(@temporary, 'bin')
    FileUtils.mkdir_p([File.join(@source, 'lang'), scripts, bin])
    File.write(File.join(@source, 'phontab'), 'table-original')
    File.write(File.join(@source, 'phondata'), 'data-original')
    File.write(File.join(@source, 'lang/pt'), 'voice-original')
    @script = File.join(scripts, 'bundle_espeak_ng_data.sh')
    FileUtils.cp(SCRIPT, @script)
    @trace = File.join(@temporary, 'copies')
    File.write(File.join(bin, 'ditto'), <<~SH)
      #!/bin/sh
      printf 'copy\n' >> "$ESPEAK_TEST_TRACE"
      exec /usr/bin/ditto "$@"
    SH
    File.chmod(0o755, File.join(bin, 'ditto'))
    @build = File.join(@temporary, 'build')
    @destination = File.join(@build, 'Fixture.app/Contents/Resources/espeak-ng-data')
    @environment = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
      'TARGET_BUILD_DIR' => @build,
      'UNLOCALIZED_RESOURCES_FOLDER_PATH' => 'Fixture.app/Contents/Resources',
      'CONVERTER_FFI_ENABLE_PIPER' => '1',
      'ESPEAK_TEST_TRACE' => @trace
    }
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.directory?(@temporary)
  end

  def bundle(extra = {})
    Open3.capture3(@environment.merge(extra), '/bin/bash', @script)
  end

  def bundle_success
    output, error, status = bundle
    assert status.success?, "#{output}\n#{error}"
    output
  end

  def copies
    File.exist?(@trace) ? File.read(@trace).lines.size : 0
  end

  def change_without_timestamp_or_size(path)
    stat = File.stat(path)
    bytes = File.binread(path)
    bytes.setbyte(0, bytes.getbyte(0) ^ 1)
    File.binwrite(path, bytes)
    File.utime(stat.atime, stat.mtime, path)
  end

  def test_identical_tree_skips_copy_and_preserves_file_metadata
    bundle_success
    target = File.join(@destination, 'phontab')
    sentinel = Time.at(1_600_000_000)
    File.utime(sentinel, sentinel, target)
    inode = File.stat(target).ino
    output = bundle_success
    assert_equal 1, copies, 'Unchanged resource tree must not be recopied'
    assert_equal sentinel, File.mtime(target)
    assert_equal inode, File.stat(target).ino
    assert_includes output, 'preserved existing resources'
  end

  def test_same_size_same_time_source_change_is_copied
    bundle_success
    change_without_timestamp_or_size(File.join(@source, 'phontab'))
    bundle_success
    assert_equal 2, copies
    assert_equal File.binread(File.join(@source, 'phontab')), File.binread(File.join(@destination, 'phontab'))
  end

  def test_same_size_same_time_destination_corruption_is_repaired
    bundle_success
    change_without_timestamp_or_size(File.join(@destination, 'phondata'))
    bundle_success
    assert_equal 2, copies
    assert_equal File.binread(File.join(@source, 'phondata')), File.binread(File.join(@destination, 'phondata'))
  end

  def test_new_and_missing_files_are_copied
    bundle_success
    File.write(File.join(@source, 'lang/new'), 'new-language')
    File.unlink(File.join(@destination, 'lang/pt'))
    bundle_success
    assert_equal 2, copies
    assert_equal 'new-language', File.read(File.join(@destination, 'lang/new'))
    assert_equal 'voice-original', File.read(File.join(@destination, 'lang/pt'))
  end

  def test_incomplete_source_is_rejected_before_destination_is_modified
    bundle_success
    before = File.read(File.join(@destination, 'phontab'))
    File.unlink(File.join(@source, 'phondata'))
    _output, error, status = bundle
    refute status.success?
    assert_includes error, 'did not produce complete eSpeak'
    assert_equal 1, copies
    assert_equal before, File.read(File.join(@destination, 'phontab'))
  end

  def test_disabled_piper_does_not_create_resources
    FileUtils.remove_entry(@source)
    _output, error, status = bundle('CONVERTER_FFI_ENABLE_PIPER' => '0')
    assert status.success?, error
    assert_equal 0, copies
    refute File.exist?(@destination)
  end
end
