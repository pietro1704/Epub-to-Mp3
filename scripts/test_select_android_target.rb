# frozen_string_literal: true

# Tests for the Android development target selector (ported from test_android_target_selection.py).
# Only fixture JSON and fixture AVD directories are used; no adb/emulator is invoked.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative 'select_android_target'

class SelectAndroidTargetTest < Minitest::Test
  SCRIPT = File.expand_path('select_android_target.rb', __dir__)
  Selector = SelectAndroidTarget
  USAGE = "usage: select_android_target.rb [-h] (--devices-json | --lightest-avd)\n"

  def setup
    @root = Dir.mktmpdir('android avd root ')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def avd(name, config)
    directory = File.join(@root, "#{name}.avd")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'config.ini'), config)
  end

  def run_script(*args, input: '', env: {})
    Open3.capture3({ 'HOME' => File.join(@root, 'home') }.merge(env), RbConfig.ruby, SCRIPT, *args, stdin_data: input)
  end

  def test_prefers_a_connected_android_device_over_an_emulator
    selected = Selector.select_running_android_device(
      [
        { 'id' => 'emulator-5554', 'targetPlatform' => 'android-x64', 'emulator' => true },
        { 'id' => 'R5CT123', 'targetPlatform' => 'android-arm64', 'emulator' => false }
      ]
    )

    assert_equal 'R5CT123', selected
  end

  def test_uses_a_running_emulator_when_no_phone_is_connected
    assert_equal 'emulator-5554', Selector.select_running_android_device(
      [{ 'id' => 'emulator-5554', 'targetPlatform' => 'android-x64', 'emulator' => true }]
    )
  end

  def test_selects_the_lightest_available_avd
    avd('Pixel_Heavy', "hw.ramSize=4096\nhw.lcd.width=1440\nhw.lcd.height=3120\nhw.cpu.ncore=4\n")
    avd('Pixel_Light', "hw.ramSize=1536\nhw.lcd.width=720\nhw.lcd.height=1280\nhw.cpu.ncore=2\n")

    assert_equal 'Pixel_Light', Selector.find_lightest_avd(@root)
  end

  # --- Ruby-only coverage of the CLI contract ---

  def test_device_filtering_ignores_non_android_and_missing_ids
    devices = [
      { 'id' => 'macos', 'targetPlatform' => 'darwin', 'emulator' => false },
      { 'id' => '', 'targetPlatform' => 'android-arm64', 'emulator' => false },
      { 'targetPlatform' => 'android-arm64' },
      { 'id' => 'NULLPLATFORM', 'targetPlatform' => nil },
      { 'id' => 'emu', 'targetPlatform' => 'Android-X64', 'emulator' => true },
      { 'id' => 42, 'targetPlatform' => 'android-arm', 'emulator' => 0 }
    ]
    assert_equal '42', Selector.select_running_android_device(devices)
    assert_equal 'emu', Selector.select_running_android_device(devices.first(5))
    assert_nil Selector.select_running_android_device(devices.first(4))
  end

  def test_devices_json_cli_prints_id_or_exits_one
    json = JSON.generate([{ 'id' => 'R5CT123', 'targetPlatform' => 'android-arm64', 'emulator' => false }])
    stdout, stderr, status = run_script('--devices-json', input: json)
    assert_equal [0, "R5CT123\n", ''], [status.exitstatus, stdout, stderr]
    stdout, _, status = run_script('--devices-json', input: '[]')
    assert_equal [1, ''], [status.exitstatus, stdout]
    stdout, stderr, status = run_script('--devices-json', input: 'not json')
    assert_equal [1, ''], [status.exitstatus, stdout]
    assert_includes stderr, 'malformed devices JSON'
    _, _, status = run_script('--devices-json', input: '{}')
    assert_equal 1, status.exitstatus
  end

  def test_lightest_avd_cli_uses_android_avd_home_and_exits_one_when_empty
    avd('Only', "hw.ramSize=2048\n")
    stdout, stderr, status = run_script('--lightest-avd', env: { 'ANDROID_AVD_HOME' => @root })
    assert_equal [0, "Only\n", ''], [status.exitstatus, stdout, stderr]
    stdout, _, status = run_script('--lightest-avd', env: { 'ANDROID_AVD_HOME' => File.join(@root, 'none') })
    assert_equal [1, ''], [status.exitstatus, stdout]
  end

  def test_lightest_avd_defaults_to_home_android_avd
    home = File.join(@root, 'home')
    FileUtils.mkdir_p(File.join(home, '.android/avd/Home_Device.avd'))
    File.write(File.join(home, '.android/avd/Home_Device.avd/config.ini'), "hw.ramSize=1G\n")
    stdout, _, status = run_script('--lightest-avd', env: { 'ANDROID_AVD_HOME' => nil })
    assert_equal [0, "Home_Device\n"], [status.exitstatus, stdout]
    assert_equal '.', Selector.default_avd_root({ 'ANDROID_AVD_HOME' => '' })
  end

  def test_size_parsing_matches_python_rules
    assert_equal 2048, Selector.size_mebibytes('2G', 1)
    assert_equal 1536, Selector.size_mebibytes(' 1.5 gb ', 1)
    assert_equal 1, Selector.size_mebibytes('1024K', 7)
    assert_equal 0, Selector.size_mebibytes('512KB', 7)
    assert_equal 800, Selector.size_mebibytes('800MB', 7)
    assert_equal 720, Selector.size_mebibytes('720', 7)
    assert_equal 7, Selector.size_mebibytes('', 7)
    assert_equal 7, Selector.size_mebibytes(nil, 7)
    assert_equal 7, Selector.size_mebibytes('2T', 7)
    assert_equal 7, Selector.size_mebibytes('-1', 7)
  end

  def test_config_parsing_skips_comments_and_keeps_first_equals
    avd('Cfg', "# hw.ramSize=1\n  #x=y\nhw.ramSize=3G\nnoequals\nkey=a=b\r\nlast=1")
    config = Selector.read_avd_config(File.join(@root, 'Cfg.avd/config.ini'))
    assert_equal({ 'hw.ramSize' => '3G', 'key' => 'a=b', 'last' => '1' }, config)
  end

  def test_tie_breaks_on_lowercase_name_and_defaults_apply
    avd('beta', "hw.ramSize=1024\n")
    avd('Alpha', "hw.ramSize=1024\n")
    avd('Tiny.Phone', "hw.ramSize=1024\nhw.lcd.width=100\nhw.lcd.height=100\n")
    assert_equal 'Tiny.Phone', Selector.find_lightest_avd(@root)
    File.write(File.join(@root, 'Tiny.Phone.avd/config.ini'), "hw.ramSize=1024\n")
    assert_equal 'Alpha', Selector.find_lightest_avd(@root)
    FileUtils.mkdir_p(File.join(@root, 'not-an-avd'))
    assert_nil Selector.find_lightest_avd(File.join(@root, 'not-an-avd'))
  end

  def test_avd_root_with_glob_characters_is_literal
    root = File.join(@root, 'odd [root] {x}')
    FileUtils.mkdir_p(File.join(root, 'Bracket.avd'))
    File.write(File.join(root, 'Bracket.avd/config.ini'), "hw.ramSize=1024\n")
    assert_equal 'Bracket', Selector.find_lightest_avd(root)
  end

  def test_argument_errors_match_argparse_and_exit_two
    {
      [] => 'one of the arguments --devices-json --lightest-avd is required',
      %w[--devices-json --lightest-avd] => 'argument --lightest-avd: not allowed with argument --devices-json',
      %w[--devices-json extra] => 'unrecognized arguments: extra',
      %w[--devices-json=1] => "argument --devices-json: ignored explicit argument '1'"
    }.each do |argv, message|
      stdout, stderr, status = run_script(*argv)
      assert_equal 2, status.exitstatus, argv.inspect
      assert_equal '', stdout
      assert_equal "#{USAGE}select_android_target.rb: error: #{message}\n", stderr, argv.inspect
    end
  end

  def test_abbreviations_repeats_and_help
    assert_equal ['--lightest-avd', nil], Selector.parse_arguments(%w[--light], stdout: StringIO.new, stderr: StringIO.new)
    assert_equal ['--devices-json', nil],
                 Selector.parse_arguments(%w[--devices-json --d], stdout: StringIO.new, stderr: StringIO.new)
    stdout = StringIO.new
    assert_equal [nil, 0], Selector.parse_arguments(%w[--help], stdout: stdout, stderr: StringIO.new)
    assert stdout.string.start_with?(USAGE)
  end
end
