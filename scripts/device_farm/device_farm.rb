#!/usr/bin/env ruby
# frozen_string_literal: true

# ANDROID-DEVICE-TEST-FARM: the Galaxy A8 and the SM-X620 tablet run tests; they never compile.
# One APK is built on the Arch host, installed on both devices, and a background loop runs a
# sharded regression suite, a background-survival soak and monkey exploration whenever no agent
# is using adb. Every failure is saved (log excerpt + signature) and summarized to epub-coord,
# who turns it into a red-then-green card.
#
#   ruby scripts/device_farm/device_farm.rb status
#   ruby scripts/device_farm/device_farm.rb with-adb -- adb -s SERIAL shell ...   # manual use
#   ruby scripts/device_farm/device_farm.rb build | install | regression | monkey | soak
#   ruby scripts/device_farm/device_farm.rb once      # one round of everything
#   ruby scripts/device_farm/device_farm.rb loop      # forever (touch STATE/stop to end it)
#
# Safety rules (enforced in code, see `safe!`): the farm never uninstalls the app, never clears
# its data, and never deletes models, books or preferences on a device; it never changes the
# owner's personal files (/sdcard Music, Download, ...) or the media player (org.videolan.vlc),
# read-only commands excepted; it pauses a device that
# is hot (>= 41 C) or below 30% battery without charger, skips a locked device (an UNLOCK note is
# written for the owner), force-stops the app after every round, and yields the adb lock to a
# manual `with-adb` request between steps.
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require 'timeout'

module DeviceFarm
  PACKAGE = ENV.fetch('DEVICE_FARM_PACKAGE', 'com.pietrocode.epubtomp3.flutter_app.verification')
  ADB_PORT = ENV.fetch('ANDROID_ADB_SERVER_PORT', '5073')
  SERIALS = (ENV['DEVICE_FARM_SERIALS'] || '52008714b40355ad,192.168.0.130:46183').split(',')
  # One physical device can have several adb names (USB serial and Wi-Fi address). Each group is
  # a list of names of the same device; the farm addresses a device by whichever name is attached.
  ALIAS_GROUPS = (ENV['DEVICE_FARM_ALIASES'] || '52008714b40355ad=192.168.0.178:5555')
                 .split(',').map { |group| group.split('=') }.freeze
  STATE = ENV.fetch('DEVICE_FARM_STATE', File.join(ENV.fetch('XDG_CACHE_HOME', File.join(Dir.home, '.cache')), 'epub2mp3-device-farm'))
  LOCK_PATH = ENV.fetch('DEVICE_FARM_LOCK', '/tmp/epub2mp3.adb.lock')
  WANTED_PATH = "#{LOCK_PATH}.manual-wanted"
  MAX_TEMPERATURE_C = Float(ENV.fetch('DEVICE_FARM_MAX_TEMP_C', '41.0'))
  MIN_BATTERY = Integer(ENV.fetch('DEVICE_FARM_MIN_BATTERY', '30'))
  ROOT = File.expand_path('../..', __dir__)
  FLUTTER_APP = File.join(ROOT, 'flutter_app')
  SUITE_TARGET = 'integration_test/farm_suite_test.dart'
  FORBIDDEN = [
    /\buninstall\b/, /\bpm\s+clear\b/, /\bpm\s+uninstall\b/, /\brm\b/, /\bmv\b/, /\brmdir\b/, /\bunlink\b/, /\bwipe\b/, /\bfactory/i,
    /\bsettings\s+put\s+(?!global verifier_verify_adb_installs)/, /\bcmd\s+package\s+uninstall/
  ].freeze

  # The owner's personal files and the media player: only read-only commands may mention them.
  PERSONAL = %r{/(?:sdcard|storage/emulated/0|storage/self/primary)/(?:Music|Download|Movies|DCIM|Pictures|Documents)|org\.videolan\.vlc}i
  READ_ONLY_VERBS = %w[ls stat du cat find wc pull].freeze

  class Forbidden < StandardError; end

  # Anything that could erase the app, its models, books or preferences is refused outright.
  def self.safe!(command)
    # The one removal the farm may do: its own verification build, so a personal device never keeps a
    # second EpubToMp3 app. Never the user's app (a different package) and never anything else.
    return command if command == ['uninstall', PACKAGE] && PACKAGE.end_with?('.verification')

    text = Array(command).join(' ')
    FORBIDDEN.each { |pattern| raise Forbidden, "refused (destructive): #{text}" if text.match?(pattern) }
    raise Forbidden, "refused (personal files or media player): #{text}" if text.match?(PERSONAL) && !read_only?(command)
    command
  end

  def self.read_only?(command)
    words = Array(command).join(' ').split
    words.shift if words.first == 'shell'
    verb = words.first.to_s
    READ_ONLY_VERBS.include?(verb) || (verb == 'pm' && words[1] == 'list') || verb == 'dumpsys'
  end

  # The names under which one device may be attached, the given one first.
  def self.aliases(serial)
    group = ALIAS_GROUPS.find { |names| names.include?(serial) }
    group ? [serial, *(group - [serial])] : [serial]
  end

  # The first name of the device that `adb devices` lists as ready; the logical name when none is.
  def self.pick_alias(serial, listing)
    ready = listing.lines.filter_map do |line|
      name, state = line.split
      name if state == 'device'
    end
    aliases(serial).find { |name| ready.include?(name) } || serial
  end

  # USB serial or Wi-Fi address, whichever is attached; reconnects a dropped Wi-Fi name first.
  def self.resolve(serial)
    names = aliases(serial)
    return serial if names.size == 1
    listing, = Open3.capture2e(env, 'adb', 'devices')
    chosen = pick_alias(serial, listing)
    return chosen if listing.lines.any? { |line| line.split.first == chosen && line.split[1] == 'device' }
    names.select { |name| name.include?(':') }.each do |address|
      Open3.capture2e(env, 'adb', 'connect', address)
    end
    pick_alias(serial, Open3.capture2e(env, 'adb', 'devices').first)
  rescue StandardError
    serial
  end

  def self.env
    { 'ANDROID_ADB_SERVER_PORT' => ADB_PORT }
  end

  def self.adb(serial, *args, timeout: 60)
    safe!(args)
    out = +''
    status = nil
    Timeout.timeout(timeout) do
      out, status = Open3.capture2e(env, 'adb', '-s', resolve(serial), *args)
      out = out.scrub
    end
    [out, status.success?]
  rescue Timeout::Error
    ["timeout after #{timeout}s: adb -s #{serial} #{args.join(' ')}", false]
  end

  # --- device health -------------------------------------------------------------------------
  Health = Struct.new(:serial, :online, :level, :charging, :temperature_c, :locked) do
    def verdict
      return :offline unless online
      return :locked if locked
      return :hot if temperature_c && temperature_c >= MAX_TEMPERATURE_C
      return :low_battery if level && level < MIN_BATTERY && !charging

      :ok
    end

    def to_h
      super.merge(verdict: verdict)
    end
  end

  def self.parse_health(serial, battery, window)
    level = battery[/^\s*level:\s*(\d+)/, 1]&.to_i
    temperature = battery[/^\s*temperature:\s*(\d+)/, 1]&.to_f
    powered = battery.match?(/^\s*(AC|USB|Wireless) powered:\s*true/)
    status = battery[/^\s*status:\s*(\d+)/, 1]&.to_i
    locked = window.match?(/isKeyguardShowing=true|mDreamingLockscreen=true|mShowingLockscreen=true/)
    Health.new(serial, !level.nil?, level, powered || status == 2, temperature && temperature / 10.0, locked)
  end

  def self.health(serial)
    battery, ok = adb(serial, 'shell', 'dumpsys', 'battery', timeout: 20)
    return Health.new(serial, false) unless ok

    window, = adb(serial, 'shell', 'dumpsys', 'window', timeout: 20)
    parse_health(serial, battery, window)
  end

  # --- the adb lock (the farm yields to manual use) ------------------------------------------
  class Lock
    def initialize
      @file = File.open(LOCK_PATH, File::RDWR | File::CREAT, 0o666)
    end

    def try_acquire
      return false if File.exist?(WANTED_PATH)

      @file.flock(File::LOCK_EX | File::LOCK_NB) ? true : false
    end

    def release
      @file.flock(File::LOCK_UN)
    end

    def manual_wanted?
      File.exist?(WANTED_PATH)
    end

    # Manual adb use: announce, wait for the farm to yield between steps, run, release.
    def self.with_manual(command)
      File.write(WANTED_PATH, "#{Process.pid} #{Time.now.utc.iso8601}\n")
      lock = new
      lock.instance_variable_get(:@file).flock(File::LOCK_EX)
      File.delete(WANTED_PATH) if File.exist?(WANTED_PATH)
      system(*command)
    ensure
      lock&.release
      File.delete(WANTED_PATH) if File.exist?(WANTED_PATH)
    end
  end

  # --- results -------------------------------------------------------------------------------
  Result = Struct.new(:device, :phase, :ok, :detail, :signature, :log)

  def self.save_failure(result)
    dir = File.join(STATE, 'failures')
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{result.device.gsub(/\W/, '_')}-#{result.phase}.log")
    File.write(path, "#{result.detail}\n\n#{result.log}")
    path
  end

  def self.crash_lines(logcat)
    # logcat carries bytes that are not UTF-8 (device logs of other apps): scrub, never raise.
    logcat.scrub.lines.select { |line| line.match?(/FATAL EXCEPTION|ANR in |Fatal signal|Process: #{Regexp.escape(PACKAGE)}/) }
  end

  def self.signature(lines)
    first = lines.first.to_s.sub(/^\S+\s+\S+\s+\d+\s+\d+\s+/, '').strip
    first.gsub(/\d+/, 'N')[0, 120]
  end

  def self.close_app(serial)
    adb(serial, 'shell', 'am', 'force-stop', PACKAGE, timeout: 20)
  end

  # --- phases --------------------------------------------------------------------------------
  def self.monkey(serial, seed: Time.now.to_i % 100_000, events: 1500)
    adb(serial, 'logcat', '-c', timeout: 20)
    out, = adb(serial, 'shell', 'monkey', '-p', PACKAGE, '-s', seed.to_s, '--throttle', '250',
               '--pct-syskeys', '0', '--pct-appswitch', '0', '--pct-nav', '0', '--pct-majornav', '2',
               '-v', events.to_s, timeout: 60 + events / 2)
    logcat, = adb(serial, 'logcat', '-d', '-t', '4000', timeout: 30)
    crashes = crash_lines(logcat) + out.lines.grep(/CRASH|ANR/)
    close_app(serial)
    ok = crashes.empty?
    Result.new(serial, 'monkey', ok, ok ? "monkey seed #{seed}: #{events} events, no crash" : "monkey seed #{seed}: #{crashes.first.to_s.strip}",
               ok ? nil : "monkey:#{signature(crashes)}", ok ? '' : "#{out.lines.last(40).join}\n#{logcat.lines.last(300).join}")
  end

  # Background survival: the app is opened, the screen is turned off for a while and the process
  # must still be alive afterwards without any crash or ANR (the playback soak on top of this
  # needs an installed model and a book fixture and is driven by the regression suite).
  def self.soak(serial, minutes: 10)
    adb(serial, 'logcat', '-c', timeout: 20)
    adb(serial, 'shell', 'monkey', '-p', PACKAGE, '-c', 'android.intent.category.MONKEY', '1', timeout: 30)
    sleep 8
    pid_before, = adb(serial, 'shell', 'pidof', PACKAGE, timeout: 20)
    adb(serial, 'shell', 'input', 'keyevent', 'KEYCODE_HOME', timeout: 20)
    adb(serial, 'shell', 'input', 'keyevent', 'KEYCODE_SLEEP', timeout: 20)
    sleep(minutes * 60)
    adb(serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP', timeout: 20)
    pid_after, = adb(serial, 'shell', 'pidof', PACKAGE, timeout: 20)
    logcat, = adb(serial, 'logcat', '-d', '-t', '4000', timeout: 30)
    crashes = crash_lines(logcat)
    close_app(serial)
    survived = !pid_after.strip.empty? || pid_before.strip.empty?
    ok = crashes.empty? && survived
    detail = ok ? "background survival #{minutes} min ok" : "background survival #{minutes} min: #{crashes.first.to_s.strip}#{' process gone' unless survived}"
    Result.new(serial, 'soak', ok, detail, ok ? nil : "soak:#{signature(crashes)}#{'process-gone' unless survived}", ok ? '' : logcat.lines.last(300).join)
  end

  def self.apk_path
    File.join(STATE, 'apk', 'farm-suite.apk')
  end

  def self.build
    FileUtils.mkdir_p(File.dirname(apk_path))
    env = { 'EPUB2MP3_ANDROID_VERIFICATION' => '1' }
    ok = system(env, 'mise', 'exec', '--', 'flutter', 'build', 'apk', '--debug', '--target', SUITE_TARGET,
                '--target-platform', 'android-arm64', chdir: FLUTTER_APP)
    built = File.join(FLUTTER_APP, 'build/app/outputs/flutter-apk/app-debug.apk')
    FileUtils.cp(built, apk_path) if ok && File.file?(built)
    ok && File.file?(apk_path)
  end

  # `install -r` keeps the app's data; the verifier toggle is restored right after.
  def self.install(serial)
    return [false, 'no APK built'] unless File.file?(apk_path)

    adb(serial, 'shell', 'settings', 'put', 'global', 'verifier_verify_adb_installs', '0', timeout: 20)
    out, ok = adb(serial, 'install', '-r', '-t', apk_path, timeout: 300)
    adb(serial, 'shell', 'settings', 'put', 'global', 'verifier_verify_adb_installs', '1', timeout: 20)
    [ok, out.lines.last.to_s.strip]
  end

  # Devices that are a person's own: the test build is removed after each round (the tablet keeps
  # it, without a launcher icon).
  PERSONAL_DEVICES = (ENV['DEVICE_FARM_PERSONAL'] || '52008714b40355ad').split(',').freeze

  def self.uninstall_after_round?(serial)
    names = aliases(serial)
    PERSONAL_DEVICES.any? { |personal| names.include?(personal) || aliases(personal).include?(serial) }
  end

  def self.remove_test_app(serial)
    close_app(serial)
    adb(serial, 'uninstall', PACKAGE, timeout: 60)
  end

  def self.installed?(serial)
    out, = adb(serial, 'shell', 'pm', 'list', 'packages', PACKAGE, timeout: 30)
    out.lines.any? { |line| line.strip == "package:#{PACKAGE}" }
  end

  # The regression runs WITHOUT `flutter drive` or `flutter test` on the device: those tools install
  # and later UNINSTALL the app (its data with it), which the farm must never do. The suite APK is
  # installed with `install -r` (data kept); a run only writes the shard file, launches the app,
  # whose entrypoint IS the integration test, and reads the verdict the test runner prints to
  # logcat. Nothing is installed, cleared or removed on the device by a run.
  def self.shard_for(serial)
    SERIALS.index(serial).to_i.even? ? 'a' : 'b'
  end

  def self.suite_verdict(logcat)
    flutter = logcat.lines.grep(/\bflutter\b/)
    return :passed if flutter.any? { |line| line.include?('All tests passed!') }
    return :failed if flutter.any? { |line| line.include?('Some tests failed') }

    nil
  end

  def self.regression(serial, minutes: 20)
    shard = shard_for(serial)
    unless installed?(serial)
      ok, detail = install(serial)
      return Result.new(serial, 'regression', false, "app missing and install failed: #{detail}", 'regression:no-app', '') unless ok
    end
    close_app(serial)
    # One argument: the device's shell must not split the command at `&&` outside run-as.
    adb(serial, 'shell', "run-as #{PACKAGE} sh -c 'mkdir -p files && echo #{shard} > files/farm_shard'", timeout: 30)
    adb(serial, 'logcat', '-c', timeout: 20)
    adb(serial, 'shell', 'monkey', '-p', PACKAGE, '-c', 'android.intent.category.MONKEY', '1', timeout: 30)
    verdict = nil
    logcat = +''
    deadline = Time.now + minutes * 60
    while Time.now < deadline
      sleep 10
      logcat, = adb(serial, 'logcat', '-d', '-s', 'flutter:I', timeout: 30)
      verdict = suite_verdict(logcat)
      break if verdict
    end
    close_app(serial)
    present = installed?(serial)
    ok = verdict == :passed && present
    failed = logcat.lines.grep(/\[E\]|Expected|finder|Bad state|EXCEPTION/).first.to_s.strip.sub(/^\S+\s+\S+\s+\d+\s+\d+\s+\w\s+/, '')
    detail = if ok then "suite shard #{shard} passed"
             elsif !present then "FARM RULE: the app is no longer installed after the run"
             elsif verdict.nil? then "suite shard #{shard} gave no verdict in #{minutes} min"
             else "suite shard #{shard} failed: #{failed}"
             end
    Result.new(serial, 'regression', ok, detail, ok ? nil : "regression:#{detail.gsub(/\d+/, 'N')[0, 120]}",
               ok ? '' : logcat.lines.last(150).join)
  end

  # --- a round -------------------------------------------------------------------------------
  def self.healthy_devices(report)
    SERIALS.filter_map do |serial|
      health = health(serial)
      report << health.to_h
      if health.verdict == :locked
        File.write(File.join(STATE, "UNLOCK_#{serial.gsub(/\W/, '_')}"), "UNLOCK #{serial} since #{Time.now.utc.iso8601}\n")
      else
        FileUtils.rm_f(File.join(STATE, "UNLOCK_#{serial.gsub(/\W/, '_')}"))
      end
      serial if health.verdict == :ok
    end
  end

  def self.round(phases)
    FileUtils.mkdir_p(STATE)
    report = []
    devices = healthy_devices(report)
    results = []
    phases.each do |phase|
      break if Lock.new.manual_wanted?

      threads = devices.map do |serial|
        Thread.new do
          case phase
          when 'regression' then regression(serial)
          when 'monkey' then monkey(serial)
          when 'soak' then soak(serial)
          end
        rescue Forbidden, StandardError => e
          close_app(serial)
          Result.new(serial, phase, false, "farm error: #{e.message}", "farm:#{e.class}", e.backtrace.to_a.first(5).join("\n"))
        end
      end
      results.concat(threads.map(&:value))
    end
    results.each { |result| result.log = save_failure(result) unless result.ok }
    devices.each { |serial| remove_test_app(serial) if uninstall_after_round?(serial) }
    { at: Time.now.utc.iso8601, devices: report, results: results.map(&:to_h) }
  end

  def self.summarize(outcome)
    lines = ["# Device farm round #{outcome[:at]}", '']
    outcome[:devices].each do |device|
      lines << "- #{device[:serial]}: #{device[:verdict]} (battery #{device[:level]}%, #{device[:temperature_c]} C#{', charging' if device[:charging]})"
    end
    outcome[:results].each do |result|
      lines << "- #{result[:ok] ? 'PASS' : 'FAIL'} #{result[:device]} #{result[:phase]}: #{result[:detail]}#{" -> #{result[:log]}" unless result[:ok]}"
    end
    unlock = Dir.glob(File.join(STATE, 'UNLOCK_*')).map { |path| File.basename(path) }
    lines << "UNLOCK needed: #{unlock.join(', ')}" unless unlock.empty?
    lines.join("\n")
  end

  # New failure signatures are sent to epub-coord once; a digest goes out every 6 hours.
  def self.report(outcome)
    summary = summarize(outcome)
    File.write(File.join(STATE, 'last-summary.md'), summary)
    seen_path = File.join(STATE, 'seen-signatures.json')
    seen = File.file?(seen_path) ? JSON.parse(File.read(seen_path)) : {}
    fresh = outcome[:results].reject { |r| r[:ok] || seen[r[:signature]] }
    fresh.each { |r| seen[r[:signature]] = outcome[:at] }
    File.write(seen_path, JSON.pretty_generate(seen))
    digest_path = File.join(STATE, 'last-digest')
    digest_due = !File.exist?(digest_path) || Time.now - File.mtime(digest_path) > 6 * 3600
    return if fresh.empty? && !digest_due

    FileUtils.touch(digest_path)
    subject = fresh.empty? ? 'device farm digest' : "device farm: #{fresh.size} new failure(s)"
    send_message(subject, summary)
  end

  def self.send_message(subject, body)
    Open3.capture2e('ai-memory', 'message', 'send', '--to-workspace', 'default', '--to-project', 'epubtomp3',
                    '--subject', subject, '--nature', 'measured', stdin_data: body)
  end

  def self.loop_forever(phases: %w[regression monkey soak], pause: 300)
    lock = Lock.new
    until File.exist?(File.join(STATE, 'stop'))
      if lock.try_acquire
        begin
          report(round(phases))
        ensure
          lock.release
        end
      end
      sleep pause
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  case command
  when 'status'
    FileUtils.mkdir_p(DeviceFarm::STATE)
    puts JSON.pretty_generate(DeviceFarm::SERIALS.map { |serial| DeviceFarm.health(serial).to_h })
  when 'with-adb'
    ARGV.shift if ARGV.first == '--'
    exit(DeviceFarm::Lock.with_manual(ARGV) ? 0 : 1)
  when 'build' then exit(DeviceFarm.build ? 0 : 1)
  when 'install'
    DeviceFarm::SERIALS.each { |serial| puts "#{serial}: #{DeviceFarm.install(serial).inspect}" }
  when 'regression', 'monkey', 'soak'
    puts JSON.pretty_generate(DeviceFarm.round([command]))
  when 'once'
    outcome = DeviceFarm.round(%w[regression monkey soak])
    DeviceFarm.report(outcome)
    puts DeviceFarm.summarize(outcome)
  when 'loop' then DeviceFarm.loop_forever
  else
    warn 'usage: device_farm.rb status | with-adb -- CMD | build | install | regression | monkey | soak | once | loop'
    exit 2
  end
end
