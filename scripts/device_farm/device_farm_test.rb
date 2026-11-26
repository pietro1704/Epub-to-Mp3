# frozen_string_literal: true

# Host tests of the device farm rules (no device needed):
#   ruby scripts/device_farm/device_farm_test.rb
require 'minitest/autorun'
require 'tmpdir'

ENV['DEVICE_FARM_LOCK'] = File.join(Dir.tmpdir, "farm-test-#{Process.pid}.lock")
ENV['DEVICE_FARM_STATE'] = Dir.mktmpdir('farm-state')
require_relative 'device_farm'

class DeviceFarmTest < Minitest::Test
  BATTERY = <<~DUMP
    Current Battery Service state:
      AC powered: false
      USB powered: true
      status: 2
      level: %<level>d
      temperature: %<temperature>d
  DUMP

  def health(level:, temperature:, locked: false, powered: true)
    battery = format(BATTERY, level: level, temperature: temperature)
    battery = battery.sub('USB powered: true', 'USB powered: false').sub('status: 2', 'status: 3') unless powered
    window = locked ? "isKeyguardShowing=true\n" : "mShowingDream=false mDreamingLockscreen=false\n"
    DeviceFarm.parse_health('serial', battery, window)
  end

  def test_a_healthy_device_runs
    assert_equal :ok, health(level: 80, temperature: 310).verdict
  end

  def test_a_hot_device_pauses_at_41_degrees
    assert_equal :ok, health(level: 80, temperature: 409).verdict
    assert_equal :hot, health(level: 80, temperature: 410).verdict
  end

  def test_low_battery_pauses_unless_charging
    assert_equal :low_battery, health(level: 29, temperature: 300, powered: false).verdict
    assert_equal :ok, health(level: 30, temperature: 300, powered: false).verdict
    assert_equal :ok, health(level: 10, temperature: 300, powered: true).verdict
  end

  def test_a_locked_device_is_skipped_and_an_unreadable_one_is_offline
    assert_equal :locked, health(level: 80, temperature: 300, locked: true).verdict
    assert_equal :offline, DeviceFarm.parse_health('s', 'error: device offline', '').verdict
  end

  def test_nothing_destructive_ever_reaches_a_device
    [
      %w[uninstall com.x], %w[shell pm clear com.x], %w[shell pm uninstall com.x],
      ['shell', 'rm -rf /sdcard/Download'], %w[shell settings put secure x 1], ['shell', 'cmd package uninstall com.x']
    ].each do |args|
      assert_raises(DeviceFarm::Forbidden, args.join(' ')) { DeviceFarm.safe!(args) }
    end
    # What the farm itself does is allowed: install -r, force-stop, the verifier toggle, monkey.
    [
      %w[install -r a.apk], %w[shell am force-stop com.x], %w[shell settings put global verifier_verify_adb_installs 0],
      %w[shell monkey -p com.x 100], %w[logcat -d]
    ].each { |args| assert_equal args, DeviceFarm.safe!(args) }
  end

  MDNS = <<~LIST
    List of discovered mdns services
    adb-RXGLA00Y4NL-R37H85\t_adb-tls-connect._tcp\t192.168.0.130:35429
    adb-OTHER-XYZ\t_adb-tls-connect._tcp\t192.168.0.9:41000
  LIST

  def test_a_wireless_device_is_found_by_its_mdns_name_whatever_its_port
    assert_equal '192.168.0.130:35429', DeviceFarm.pick_mdns('mdns:adb-RXGLA00Y4NL-R37H85', MDNS)
    assert_nil DeviceFarm.pick_mdns('mdns:adb-MISSING', MDNS)
    assert_nil DeviceFarm.pick_mdns('192.168.0.130:46183', MDNS), 'only mdns: names are looked up'
  end

  def test_the_farm_yields_the_lock_to_manual_use
    farm = DeviceFarm::Lock.new
    assert farm.try_acquire
    farm.release
    File.write(DeviceFarm::WANTED_PATH, 'manual')
    refute DeviceFarm::Lock.new.try_acquire, 'a manual request is pending: the farm must not start'
    File.delete(DeviceFarm::WANTED_PATH)
    free = DeviceFarm::Lock.new
    assert free.try_acquire
    free.release
  end

  def test_manual_use_waits_for_the_farm_and_cleans_up
    farm = DeviceFarm::Lock.new
    assert farm.try_acquire
    started = Time.now
    releaser = Thread.new do
      sleep 0.4
      farm.release
    end
    assert DeviceFarm::Lock.with_manual(%w[true])
    releaser.join
    assert_operator Time.now - started, :>=, 0.35
    refute File.exist?(DeviceFarm::WANTED_PATH)
  end

  def test_crash_lines_are_found_and_signatures_ignore_numbers
    logcat = "11-24 01:02:03.456  1234  1250 E AndroidRuntime: FATAL EXCEPTION: main\n" \
             "11-24 01:02:03.457  1234  1250 E AndroidRuntime: Process: #{DeviceFarm::PACKAGE}, PID: 1234\n"
    lines = DeviceFarm.crash_lines(logcat)
    assert_equal 2, lines.size
    other = "11-24 09:09:09.999  7777  7788 E AndroidRuntime: FATAL EXCEPTION: main\n"
    assert_equal DeviceFarm.signature(lines), DeviceFarm.signature(DeviceFarm.crash_lines(other))
  end

  def test_the_suite_verdict_is_read_from_the_flutter_log_lines_only
    passed = "I/flutter (1): 00:35 +1: All tests passed!\n"
    failed = "I/flutter (1): 00:35 +0 -1: Some tests failed.\n"
    noise = "I/other (2): All tests passed!\nI/flutter (1): something else\n"
    assert_equal :passed, DeviceFarm.suite_verdict(passed)
    assert_equal :failed, DeviceFarm.suite_verdict(failed)
    assert_nil DeviceFarm.suite_verdict(noise)
  end

  def test_the_farm_never_runs_a_tool_that_installs_or_removes_the_app
    source = File.read(File.expand_path('device_farm.rb', __dir__))
    refute_match(/'flutter',\s*'(drive|test)'/, source, 'flutter drive/test uninstall the app when they finish')
  end

  def test_the_summary_lists_devices_failures_and_unlock_requests
    File.write(File.join(DeviceFarm::STATE, 'UNLOCK_tablet'), 'UNLOCK tablet')
    summary = DeviceFarm.summarize(
      at: 'now',
      devices: [{ serial: 'a8', verdict: :ok, level: 90, temperature_c: 31.0, charging: true }],
      results: [{ ok: false, device: 'a8', phase: 'monkey', detail: 'crash', log: '/tmp/f.log' }]
    )
    assert_includes summary, 'FAIL a8 monkey: crash -> /tmp/f.log'
    assert_includes summary, 'UNLOCK needed: UNLOCK_tablet'
  end
  def test_the_a8_is_one_device_reachable_by_usb_serial_or_wifi_address
    usb = '52008714b40355ad'
    wifi = '192.168.0.178:5555'
    assert_equal [usb, wifi], DeviceFarm.aliases(usb)
    assert_equal [wifi, usb], DeviceFarm.aliases(wifi), 'either name resolves to the same device'
    assert_equal [DeviceFarm::SERIALS[1]], DeviceFarm.aliases(DeviceFarm::SERIALS[1]), 'the tablet has one name'
    listing = "List of devices attached\n#{wifi}\tdevice\n192.168.0.130:46183\tdevice\n"
    assert_equal wifi, DeviceFarm.pick_alias(usb, listing), 'USB unplugged: the Wi-Fi address serves'
    both = "List of devices attached\n#{usb}\tdevice\n#{wifi}\tdevice\n"
    assert_equal usb, DeviceFarm.pick_alias(usb, both), 'both attached: USB first'
    offline = "List of devices attached\n#{usb}\toffline\n#{wifi}\tdevice\n"
    assert_equal wifi, DeviceFarm.pick_alias(usb, offline)
    assert_equal usb, DeviceFarm.pick_alias(usb, "List of devices attached\n"), 'nothing attached: keep the logical name'
  end

  def test_the_owners_personal_files_and_the_media_player_are_never_changed
    [
      ['shell', 'rm /sdcard/Music/Nanda/aula1.mp3'], ['shell', 'rm', '-f', '/sdcard/Download/jardim-das-aflicoes.epub'],
      ['shell', 'mv /sdcard/Music/Nanda /sdcard/Music/x'], %w[shell rmdir /sdcard/Music/Nanda],
      %w[shell am force-stop org.videolan.vlc], %w[shell pm disable-user org.videolan.vlc],
      %w[shell monkey -p org.videolan.vlc 5], ['push', 'a.mp3', '/sdcard/Music/Nanda/'],
      %w[shell cp /sdcard/Download/a.epub /sdcard/Download/b.epub]
    ].each { |args| assert_raises(DeviceFarm::Forbidden, args.join(' ')) { DeviceFarm.safe!(args) } }
    [
      %w[shell ls /sdcard/Music/Nanda], %w[shell ls -l /sdcard/Download/jardim-das-aflicoes.epub],
      ['pull', '/sdcard/Download/jardim-das-aflicoes.epub', '/tmp/x.epub'], %w[shell stat /sdcard/Music/Nanda],
      %w[shell pm list packages org.videolan.vlc]
    ].each { |args| assert_equal args, DeviceFarm.safe!(args) }
  end

  def test_logcat_with_bytes_that_are_not_utf8_is_still_searched
    logcat = "11-24 08:59:44.170  1  1 I tag: caf\xE9 \xFF\n11-24 08:59:44.171  1  1 E AndroidRuntime: FATAL EXCEPTION: main\n".b.force_encoding('UTF-8')
    refute logcat.valid_encoding?
    lines = DeviceFarm.crash_lines(logcat)
    assert_equal 1, lines.size
    assert_includes lines.first, 'FATAL EXCEPTION'
  end

  def test_the_test_build_has_no_launcher_icon_and_the_app_is_started_without_the_launcher_category
    manifest = File.read(File.expand_path('../../flutter_app/android/app/src/main/AndroidManifest.xml', __dir__))
    gradle = File.read(File.expand_path('../../flutter_app/android/app/build.gradle.kts', __dir__))
    refute_includes manifest, 'android:name="android.intent.category.LAUNCHER"', 'the category is a manifest placeholder'
    assert_includes manifest, '${launcherCategory}'
    assert_match(/manifestPlaceholders\["launcherCategory"\]\s*=\s*"android.intent.category.LAUNCHER"/, gradle)
    verification = gradle[/getByName\("debug"\).*?\n        \}/m]
    assert_match(/EPUB2MP3_ANDROID_VERIFICATION/, verification)
    assert_match(/manifestPlaceholders\["launcherCategory"\]\s*=\s*"android.intent.category.MONKEY"/, verification)
    source = File.read(File.expand_path('device_farm.rb', __dir__))
    refute_match(/'-c', 'android.intent.category.LAUNCHER'/, source, 'the farm starts the test build through the MONKEY category')
  end

  def test_only_the_verification_app_may_be_uninstalled_and_nothing_else
    assert DeviceFarm::PACKAGE.end_with?('.verification')
    assert_equal ['uninstall', DeviceFarm::PACKAGE], DeviceFarm.safe!(['uninstall', DeviceFarm::PACKAGE])
    ['com.pietrocode.epubtomp3.flutter_app', 'org.videolan.vlc', 'com.android.chrome'].each do |package|
      assert_raises(DeviceFarm::Forbidden, package) { DeviceFarm.safe!(['uninstall', package]) }
    end
    assert_raises(DeviceFarm::Forbidden) { DeviceFarm.safe!(['shell', 'pm', 'uninstall', DeviceFarm::PACKAGE]) }
  end

  def test_a_personal_device_is_cleaned_up_after_each_round_and_the_tablet_keeps_the_hidden_app
    assert DeviceFarm.uninstall_after_round?('52008714b40355ad')
    assert DeviceFarm.uninstall_after_round?('192.168.0.178:5555'), 'either name of the A8'
    refute DeviceFarm.uninstall_after_round?('192.168.0.130:46183')
  end

  # A8 2026-11-25: the soak sent KEYCODE_SLEEP; with a PIN, WAKEUP leaves the phone on the PIN screen
  # and every later phase stalls until a person unlocks it.
  def soak_calls(window)
    calls = []
    fakes = {
      adb: lambda { |_serial, *args, **|
        calls << args.join(' ')
        [args.include?('window') ? window : '123', true]
      },
      sleep: ->(*) {},
      close_app: ->(*) {}
    }
    singleton = DeviceFarm.singleton_class
    originals = fakes.keys.to_h { |name| [name, DeviceFarm.method(name)] }
    fakes.each { |name, fake| singleton.define_method(name, &fake) }
    [calls, DeviceFarm.soak('serial', minutes: 0)]
  ensure
    originals&.each { |name, original| singleton.define_method(name, original) }
  end

  # 2026-11-26: a hand-installed app build (not the suite entrypoint) was left on the devices; the
  # regression saw the package present, never installed the suite and gave "no verdict" for 20 min.
  def test_the_regression_always_installs_the_suite_apk_even_when_the_package_is_present
    calls = []
    fakes = {
      adb: lambda { |_serial, *args, **|
        calls << args.join(' ')
        ['', true]
      },
      sleep: ->(*) {},
      close_app: ->(*) {},
      installed?: ->(*) { true },
      install: lambda { |serial|
        calls << "install #{serial}"
        [true, 'Success']
      }
    }
    singleton = DeviceFarm.singleton_class
    originals = fakes.keys.to_h { |name| [name, DeviceFarm.method(name)] }
    fakes.each { |name, fake| singleton.define_method(name, &fake) }
    DeviceFarm.regression('serial', minutes: 0)
    assert_includes calls, 'install serial'
  ensure
    originals&.each { |name, original| singleton.define_method(name, original) }
  end

  # 2026-11-26: a failing suite printed box-drawing characters; the signature kept binary bytes and
  # JSON.pretty_generate in `report` raised, which killed the whole loop service.
  def test_a_failing_suite_signature_is_valid_text_the_report_can_serialize
    log = "11-26 00:43:18.047 1 1 I flutter : \u2550\u2550\u2561 EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK\n" \
          "11-26 00:43:18.081 1 1 I flutter : 00:15 +0 -1: Some tests failed.\n"
    fakes = {
      adb: ->(_serial, *args, **) { [args.include?('logcat') && args.include?('-d') ? log.b : '', true] },
      sleep: ->(*) {},
      close_app: ->(*) {},
      installed?: ->(*) { true },
      install: ->(*) { [true, 'Success'] }
    }
    singleton = DeviceFarm.singleton_class
    originals = fakes.keys.to_h { |name| [name, DeviceFarm.method(name)] }
    fakes.each { |name, fake| singleton.define_method(name, &fake) }
    result = DeviceFarm.regression('serial', minutes: 1)
    refute result.ok
    JSON.pretty_generate(result.signature => 1)
  ensure
    originals&.each { |name, original| singleton.define_method(name, original) }
  end

  def test_the_soak_never_turns_off_the_screen_of_a_device_with_a_secure_lock
    ["KeyguardServiceDelegate\n  secure=true\n", "no keyguard information\n"].each do |window|
      calls, result = soak_calls(window)
      refute(calls.any? { |call| call.include?('KEYCODE_SLEEP') }, window)
      assert result.ok
      assert_match(/screen-off not exercised/, result.detail)
    end
  end

  def test_the_soak_turns_off_the_screen_of_a_device_without_a_secure_lock
    calls, result = soak_calls("KeyguardServiceDelegate\n  secure=false\n")
    assert(calls.any? { |call| call.include?('KEYCODE_SLEEP') })
    assert(calls.any? { |call| call.include?('KEYCODE_WAKEUP') })
    refute_match(/not exercised/, result.detail)
  end

  # A8 2026-11-25: `adb install` hung for 1h34 although adb() has a 300 s timeout: Timeout only
  # interrupted the Ruby thread and the adb process kept running and holding the device.
  def test_a_command_past_its_timeout_is_killed_with_its_children
    Dir.mktmpdir do |dir|
      pids = File.join(dir, 'pids')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, ok = DeviceFarm.capture({}, ['sh', '-c', "sleep 30 & echo $$ $! > #{pids}; wait"], timeout: 1)
      refute ok
      assert_match(/timeout after 1s/, out)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      File.read(pids).split.map(&:to_i).each do |pid|
        alive = 20.times.all? do
          Process.kill(0, pid)
          !Kernel.sleep(0.1)
        rescue Errno::ESRCH
          false
        end
        refute alive, "process #{pid} still alive"
      end
    end
  end

  def test_a_command_within_its_timeout_returns_its_output
    out, ok = DeviceFarm.capture({}, ['sh', '-c', 'echo hello'], timeout: 5)
    assert ok
    assert_equal "hello\n", out
  end
end


def test_the_device_is_left_on_the_normal_app_after_the_suite
  calls = []
  DeviceFarm.singleton_class.alias_method :orig_adb_for_test, :adb
  DeviceFarm.define_singleton_method(:adb) { |*args, **_| calls << args; ['Success', true] }
  Dir.mktmpdir do |dir|
    normal = File.join(dir, 'farm-normal.apk')
    File.write(normal, 'x')
    DeviceFarm.define_singleton_method(:normal_apk_path) { normal }
    ok, = DeviceFarm.install_normal('serial')
    assert ok
    assert_includes calls.map { |c| c[1..] }, ['install', '-r', '-t', normal]
  end
  refute_includes calls.flatten, 'uninstall'
ensure
  DeviceFarm.singleton_class.alias_method :adb, :orig_adb_for_test
  DeviceFarm.singleton_class.send(:remove_method, :normal_apk_path)
end

def test_regression_reinstalls_the_normal_app_after_the_suite
  body = File.read(File.join(__dir__, 'device_farm.rb'))[/def self\.regression.*?\n  end\n/m]
  assert_operator body.index('install_normal'), :>, body.index('suite_verdict(logcat)')
end
