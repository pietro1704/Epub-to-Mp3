# frozen_string_literal: true

# Tests for scripts/select_ios_simulator.rb (ported from test_select_ios_simulator.py).
#
# The selector is the source of truth for the `IOS_DEST` value passed to
# `xcodebuild`. It reads supplied JSON or queries available devices without
# booting them, then prefers an available iPhone SE on the oldest allowed
# runtime, followed by any iPhone and any iOS device. A booted device does not
# override that order. Recent runtimes are blocked by default; if nothing safe
# matches, the selector exits non-zero with an actionable message.

require 'minitest/autorun'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require_relative 'select_ios_simulator'

class SelectIosSimulatorTest < Minitest::Test
  SCRIPT = File.expand_path('select_ios_simulator.rb', __dir__)
  IOS17 = 'com.apple.CoreSimulator.SimRuntime.iOS-17-2'
  CLEAN = { 'IOS_ALLOW_RECENT_SIMULATOR' => nil, 'IOS_MAX_SIMULATOR_MAJOR' => '17' }.freeze

  Result = Struct.new(:stdout, :stderr, :status)

  def run_script(payload, env: CLEAN, args: ['--stdin'])
    input = payload.is_a?(String) ? payload : JSON.generate(payload)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, *args, stdin_data: input)
    Result.new(stdout, stderr, status.exitstatus)
  end

  def device(name, udid, state: 'Shutdown', available: true)
    { 'name' => name, 'udid' => udid, 'state' => state, 'isAvailable' => available }
  end

  def test_selects_available_iphone_se
    result = run_script({ 'devices' => { IOS17 => [device('iPhone SE (2nd generation)', 'AAA', state: 'Booted'),
                                                   device('iPhone 15', 'BBB')] } })
    assert_equal 0, result.status, result.stderr
    assert_includes result.stdout, 'id=AAA'
    assert_includes result.stdout, 'platform=iOS Simulator'
  end

  def test_prefers_iphone_se_when_nothing_booted
    result = run_script({ 'devices' => { IOS17 => [device('iPhone 15', 'BBB'),
                                                   device('iPhone SE (3rd generation)', 'CCC')] } })
    assert_equal 0, result.status, result.stderr
    assert_includes result.stdout, 'id=CCC'
  end

  def test_falls_back_to_any_iphone
    result = run_script({ 'devices' => { IOS17 => [device('iPhone 15 Pro', 'DDD')] } })
    assert_equal 0, result.status, result.stderr
    assert_includes result.stdout, 'id=DDD'
  end

  def test_prefers_oldest_allowed_runtime_when_multiple_present
    result = run_script({ 'devices' => {
                          'com.apple.CoreSimulator.SimRuntime.iOS-16-4' => [device('iPhone SE (2nd generation)', 'OLD')],
                          IOS17 => [device('iPhone SE (3rd generation)', 'NEW')]
                        } })
    assert_equal 0, result.status, result.stderr
    assert_includes result.stdout, 'id=OLD'
  end

  def test_skips_recent_runtime_by_default_even_when_booted
    result = run_script({ 'devices' => {
                          IOS17 => [device('iPhone SE (2nd generation)', 'SAFE')],
                          'com.apple.CoreSimulator.SimRuntime.iOS-26-3' => [device('iPhone 16 Pro', 'RISKY', state: 'Booted')]
                        } })
    assert_equal 0, result.status, result.stderr
    assert_includes result.stdout, 'id=SAFE'
  end

  def test_recent_runtime_requires_explicit_opt_in
    payload = { 'devices' => { 'com.apple.CoreSimulator.SimRuntime.iOS-26-3' => [device('iPhone 16 Pro', 'RISKY')] } }
    result = run_script(payload)
    refute_equal 0, result.status
    assert_includes result.stderr.downcase, 'allowed ios simulator'

    opted_in = run_script(payload, env: { 'IOS_ALLOW_RECENT_SIMULATOR' => '1', 'IOS_MAX_SIMULATOR_MAJOR' => nil })
    assert_equal 0, opted_in.status, opted_in.stderr
    assert_includes opted_in.stdout, 'id=RISKY'
  end

  def test_live_query_failure_is_reported_without_selecting_device
    calls = []
    failed_query = lambda do |arguments|
      calls << arguments
      ['', 'fixture service unavailable', 23]
    end
    stdout = StringIO.new
    stderr = StringIO.new
    failure = assert_raises(SystemExit) do
      SelectIosSimulator.read_payload(false, stderr: stderr, runner: failed_query)
    end
    assert_equal 2, failure.status
    assert_equal [%w[xcrun simctl list -j devices available]], calls
    assert_equal '', stdout.string
    assert_includes stderr.string, 'fixture service unavailable'
  end

  def test_stdin_malformed_json_reports_error_without_querying_native_tools
    stderr = StringIO.new
    unexpected_query = ->(*) { flunk 'stdin selection must not query native tools' }
    failure = assert_raises(SystemExit) do
      SelectIosSimulator.read_payload(true, stdin: StringIO.new('{invalid'), stderr: stderr, runner: unexpected_query)
    end
    assert_equal 2, failure.status
    assert_includes stderr.string, 'malformed simctl JSON'
  end

  def test_booted_phone_does_not_override_oldest_available_se_identity
    result = run_script({ 'devices' => {
                          IOS17 => [device('iPhone 15', 'BOOTED', state: 'Booted')],
                          'com.apple.CoreSimulator.SimRuntime.iOS-15-5' => [device('iPhone SE (1st generation)', 'REQUIRED-SE')]
                        } })
    assert_equal 0, result.status, result.stderr
    assert_equal 'platform=iOS Simulator,id=REQUIRED-SE', result.stdout.strip
  end

  def test_missing_selected_identity_fails_without_printing_destination
    result = run_script({ 'devices' => { 'com.apple.CoreSimulator.SimRuntime.iOS-15-5' => [
                          { 'name' => 'iPhone SE (1st generation)', 'state' => 'Shutdown', 'isAvailable' => true }
                        ] } })
    assert_equal 1, result.status
    assert_equal '', result.stdout
    assert_includes result.stderr, 'chosen device has no UDID'
    assert_equal "select_ios_simulator: chosen device has no UDID: {'name': 'iPhone SE (1st generation)', " \
                 "'state': 'Shutdown', 'isAvailable': True}\n", result.stderr
  end

  def test_ignores_unavailable_devices
    unavailable = device('iPhone SE (2nd generation)', 'AAA', available: false)
    unavailable['availabilityError'] = 'runtime profile not found'
    result = run_script({ 'devices' => { IOS17 => [unavailable] } })
    refute_equal 0, result.status
    assert_includes result.stderr.downcase, 'no available allowed ios simulator'
  end

  def test_errors_when_no_ios_runtime
    result = run_script({ 'devices' => {} })
    refute_equal 0, result.status
    assert_includes result.stderr.downcase, 'no available allowed ios simulator'
  end

  def test_ignores_non_ios_runtimes
    result = run_script({ 'devices' => { 'com.apple.CoreSimulator.SimRuntime.watchOS-10-2' => [
                          device('Apple Watch Series 9', 'WATCH', state: 'Booted')
                        ] } })
    refute_equal 0, result.status
  end

  def test_ignores_non_iphone_when_no_iphone_present
    result = run_script({ 'devices' => { IOS17 => [device('iPad Pro (12.9-inch) (6th generation)', 'IPAD')] } })
    # iPad is acceptable as last-resort iOS Simulator target.
    assert_equal 0, result.status
    assert_includes result.stdout, 'id=IPAD'
  end

  # --- Ruby-only coverage of the CLI contract ---

  def test_no_match_message_and_status_are_exact
    result = run_script({ 'devices' => {} })
    assert_equal 1, result.status
    assert_equal '', result.stdout
    assert_equal "select_ios_simulator: no available allowed iOS simulator. Install an iOS runtime at or below " \
                 "the configured maximum.\n", result.stderr
  end

  def test_destination_output_is_one_exact_line
    result = run_script({ 'devices' => { IOS17 => [device('iPhone 15', 'X1')] } })
    assert_equal "platform=iOS Simulator,id=X1\n", result.stdout
    assert_equal '', result.stderr
  end

  def test_live_query_uses_fake_xcrun_on_path_and_never_boots
    Dir.mktmpdir('fake xcrun ') do |bin|
      log = File.join(bin, 'calls.log')
      payload = JSON.generate({ 'devices' => { IOS17 => [device('iPhone SE (3rd generation)', 'LIVE')] } })
      File.write(File.join(bin, 'xcrun'), "#!/bin/sh\necho \"$@\" >> '#{log}'\ncat <<'JSON'\n#{payload}\nJSON\n")
      FileUtils.chmod(0o755, File.join(bin, 'xcrun'))
      env = CLEAN.merge('PATH' => "#{bin}:#{ENV.fetch('PATH')}")
      result = run_script('', env: env, args: [])
      assert_equal 0, result.status, result.stderr
      assert_equal "platform=iOS Simulator,id=LIVE\n", result.stdout
      assert_equal "simctl list -j devices available\n", File.read(log)
    end
  end

  def test_live_query_failure_exit_and_message_through_fake_xcrun
    Dir.mktmpdir('fake xcrun ') do |bin|
      File.write(File.join(bin, 'xcrun'), "#!/bin/sh\necho 'fixture down' >&2\nexit 23\n")
      FileUtils.chmod(0o755, File.join(bin, 'xcrun'))
      result = run_script('', env: CLEAN.merge('PATH' => "#{bin}:#{ENV.fetch('PATH')}"), args: [])
      assert_equal 2, result.status
      assert_equal '', result.stdout
      assert_equal "select_ios_simulator: `xcrun simctl list` failed:\nfixture down\n\n", result.stderr
    end
  end

  def test_invalid_max_major_exits_two
    result = run_script({ 'devices' => {} }, env: { 'IOS_ALLOW_RECENT_SIMULATOR' => nil, 'IOS_MAX_SIMULATOR_MAJOR' => 'x' })
    assert_equal 2, result.status
    assert_equal "select_ios_simulator: IOS_MAX_SIMULATOR_MAJOR must be an integer\n", result.stderr
  end

  def test_max_major_bounds_and_default
    runtimes = { 'com.apple.CoreSimulator.SimRuntime.iOS-18-0' => [device('iPhone 16', 'R18')],
                 'com.apple.CoreSimulator.SimRuntime.iOS-17-5' => [device('iPhone 15', 'R17')] }
    assert_equal 'R17', SelectIosSimulator.select({ 'devices' => runtimes }, env: {})['udid']
    assert_equal 'R17', SelectIosSimulator.select({ 'devices' => runtimes }, env: { 'IOS_MAX_SIMULATOR_MAJOR' => '' })['udid']
    assert_equal 'R18', SelectIosSimulator.select({ 'devices' => runtimes.slice('com.apple.CoreSimulator.SimRuntime.iOS-18-0') },
                                                  env: { 'IOS_MAX_SIMULATOR_MAJOR' => ' 18 ' })['udid']
  end

  def test_runtimes_sort_numerically_and_stably
    keys = %w[iOS-17-10 iOS-17-2 iOS-9-0 iOS-17-2].each_with_index.map { |suffix, index| "#{SelectIosSimulator::RUNTIME_PREFIX}#{suffix.delete_prefix('iOS-')}#{' ' * index}" }
    devices = keys.to_h { |key| [key, []] }
    ordered = SelectIosSimulator.ios_runtimes(devices, env: {})
    assert_equal [keys[2], keys[1], keys[3], keys[0]], ordered
    assert_equal [0, 0], SelectIosSimulator.runtime_sort_key('com.apple.CoreSimulator.SimRuntime.iOS-beta')
  end

  def test_python_truthiness_for_availability_and_udid
    refute SelectIosSimulator.available?({ 'isAvailable' => 0 })
    refute SelectIosSimulator.available?({})
    assert SelectIosSimulator.available?({ 'isAvailable' => 'yes' })
    result = run_script({ 'devices' => { IOS17 => [device('iPhone 15', '')] } })
    assert_equal 1, result.status
    assert_includes result.stderr, "'udid': ''"
  end

  def test_unknown_argument_is_an_argparse_style_usage_error
    result = run_script({ 'devices' => {} }, args: ['--bogus'])
    assert_equal 2, result.status
    assert_equal '', result.stdout
    assert_equal "usage: select_ios_simulator.rb [-h] [--stdin]\nselect_ios_simulator.rb: error: " \
                 "unrecognized arguments: --bogus\n", result.stderr
  end

  def test_help_and_abbreviated_stdin
    help = run_script('', args: ['--help'])
    assert_equal 0, help.status
    assert_includes help.stdout, 'Pick the best iOS Simulator destination for `xcodebuild`.'
    abbreviated = run_script({ 'devices' => { IOS17 => [device('iPhone 15', 'AB')] } }, args: ['--std'])
    assert_equal "platform=iOS Simulator,id=AB\n", abbreviated.stdout
    explicit = run_script('', args: ['--stdin=1'])
    assert_equal 2, explicit.status
    assert_includes explicit.stderr, "argument --stdin: ignored explicit argument '1'"
  end

  def test_python_repr_formats
    assert_equal %q({'a': [1, 2.5, None, False], "b'": 'x\\ny'}),
                 SelectIosSimulator.python_repr({ 'a' => [1, 2.5, nil, false], "b'" => "x\ny" })
    assert_equal '1e+16', SelectIosSimulator.python_repr(1e16)
  end
end
