# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'espeak_runtime_assets'

# Cargo moved build-script output from build/<package>-<hash> to
# build/<package>/<hash>; the packager must find the eSpeak data in both.
class EspeakRuntimeAssetsTest < Minitest::Test
  ENTRIES = %w[phontab phondata phonindex pt_dict].freeze

  def setup
    @root = Dir.mktmpdir('espeak assets ')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def data_directory(*parts, share: 'share', complete: true)
    directory = File.join(@root, *parts, 'out', share, 'espeak-ng-data')
    FileUtils.mkdir_p(directory)
    (complete ? ENTRIES : ENTRIES.first(2)).each { |name| File.write(File.join(directory, name), 'x') }
    directory
  end

  def find
    EspeakRuntimeAssets.find(@root, %w[target/release target/espeak-data/debug])
  end

  def test_finds_the_legacy_flat_build_layout
    expected = data_directory('target', 'release', 'build', 'espeak-rs-sys-c191fb94e01774d6')
    assert_equal expected, find
  end

  def test_finds_the_hash_directory_build_layout
    expected = data_directory('target', 'release', 'build', 'espeak-rs-sys', '69ff7e289cfe9511')
    assert_equal expected, find
  end

  def test_accepts_the_build_subdirectory_and_the_debug_data_target
    expected = data_directory('target', 'espeak-data', 'debug', 'build', 'espeak-rs-sys', 'abc', share: 'build')
    assert_equal expected, find
  end

  def test_skips_incomplete_data_and_other_packages
    data_directory('target', 'release', 'build', 'espeak-rs-sys', 'partial', complete: false)
    data_directory('target', 'release', 'build', 'espeak-rs', 'other')
    assert_nil find
  end
end
