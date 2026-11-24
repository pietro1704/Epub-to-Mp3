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
end
