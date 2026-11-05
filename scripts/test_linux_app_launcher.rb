# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'shellwords'

class LinuxAppLauncherTest < Minitest::Test
  def setup
    @temporary = File.realpath(Dir.mktmpdir('epub-launcher-'))
    @bundle = File.join(@temporary, 'Books "quoted" 100% $literal `literal` \\ folder')
    @data = File.join(@temporary, 'xdg data')
    FileUtils.mkdir_p(File.join(@bundle, 'data'))
    @script = File.join(@bundle, 'install-launcher.sh')
    FileUtils.cp(File.expand_path('../flutter_app/linux/resources/install-launcher.sh', __dir__), @script)
    File.write(File.join(@bundle, 'flutter_app'), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(@bundle, 'flutter_app'))
    File.write(File.join(@bundle, 'data/app-icon.png'), 'retained icon fixture')
    @entry = File.join(@data, 'applications/com.epubtomp3.flutter_app.desktop')
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def invoke
    Open3.capture3({ 'XDG_DATA_HOME' => @data }, 'bash', @script)
  end

  def test_installs_a_literal_relocatable_launcher_and_preserves_other_apps
    FileUtils.mkdir_p(File.dirname(@entry))
    unrelated = File.join(File.dirname(@entry), 'other.desktop')
    File.write(unrelated, 'keep this application')
    _, error, status = invoke
    assert status.success?, error
    source = File.read(@entry)
    raw = source.lines.find { |line| line.start_with?('Exec=') }.strip.delete_prefix('Exec=')
    # Desktop Entry string escaping precedes its quoted Exec argument parser.
    value = raw.gsub(/\\([\\sntr])/) { { '\\' => '\\', 's' => ' ', 'n' => "\n", 't' => "\t", 'r' => "\r" }.fetch(Regexp.last_match(1)) }
    arguments = Shellwords.split(value)
    assert_equal 1, arguments.size
    assert_equal File.join(@bundle, 'flutter_app'), arguments.first.gsub('%%', '%')
    assert_includes source, 'StartupWMClass=com.epubtomp3.flutter_app'
    assert_equal 'keep this application', File.read(unrelated)
    assert_equal 0o644, File.stat(@entry).mode & 0o777
    icon = source.lines.find { |line| line.start_with?('Icon=') }.strip.delete_prefix('Icon=').gsub('\\\\', '\\')
    assert_equal File.join(@bundle, 'data/app-icon.png'), icon
    original = File.binread(@entry)
    _, error, status = invoke
    assert status.success?, error
    assert_equal original, File.binread(@entry)
    assert_empty Dir.glob(File.join(File.dirname(@entry), '.epubtomp3-launcher.*'))
  end

  def test_missing_bundle_payload_does_not_overwrite_an_existing_launcher
    FileUtils.mkdir_p(File.dirname(@entry))
    File.write(@entry, 'existing launcher')
    FileUtils.rm(File.join(@bundle, 'data/app-icon.png'))
    _, error, status = invoke
    assert_equal 2, status.exitstatus
    assert_includes error, 'extracted EpubToMp3 Linux bundle'
    assert_equal 'existing launcher', File.read(@entry)
  end

  def test_non_executable_application_is_rejected_without_creating_launchers
    File.chmod(0o644, File.join(@bundle, 'flutter_app'))
    _, _, status = invoke
    assert_equal 2, status.exitstatus
    refute File.exist?(@entry)
    refute File.exist?(@data)
  end
end
