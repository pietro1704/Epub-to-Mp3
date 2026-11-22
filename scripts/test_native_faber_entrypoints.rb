# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'json'
require 'timeout'
require 'uri'

# Real drivers/supervisor, isolated storage notes and real child processes; no native
# compiler, download, Apple service, app or device is started by these fixtures.
class NativeFaberEntrypointsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  DRIVERS = {
    'package_rust_cli.rb' => ['--package-only'],
    'build_converter_ffi_android.rb' => [],
    'build_flutter_android.rb' => ['debug'],
    'build_flutter_desktop.rb' => ['linux'],
    'verify_tts_preferences.rb' => [],
    'verify_portable_tts.rb' => [],
    'converter_ffi_local_build.rb' => [],
    'build_onnxruntime_macos.sh' => []
  }.freeze

  def setup
    @directory = File.realpath(Dir.mktmpdir('native Faber entrypoints '))
    @scripts = File.join(@directory, 'scripts')
    @bin = File.join(@directory, 'bin')
    @lock = File.join(@directory, 'lease')
    @events = File.join(@directory, 'events')
    FileUtils.mkdir_p([@scripts, @bin, File.join(@directory, 'flutter_app')])
    (DRIVERS.keys + %w[native_job.rb native_build_command.rb fetch_onnxruntime_android.rb fetch_onnxruntime_macos.rb]).each do |name|
      content = File.read(File.join(ROOT, 'scripts', name))
      content = content.gsub('/tmp/epub2mp3.heavy-job.lock', @lock)
      File.write(File.join(@scripts, name), content)
    end
    # Keep this driver fixture independent of host caches and disk capacity;
    # the real storage policy has its own fixture suite.
    File.write(File.join(@scripts, 'mac_build_budget.rb'), <<~'RUBY')
      module MacBuildBudget
        ROOT = File.expand_path('..', __dir__)
        def self.advise(*destinations)
          note = 'Fixture: build storage budget exceeded' if ENV['FIXTURE_STORAGE_BLOCKED'] == '1'
          blocked = ENV['FIXTURE_FULL_VOLUME']
          note ||= 'Fixture: destination volume is full' if destinations.any? { |path| File.expand_path(path) == blocked }
          warn "native_job: advisory, not a refusal: #{note}" if note
          note
        end
      end
      if $PROGRAM_NAME == __FILE__
        abort 'Expected check and a destination' unless ARGV.shift == 'check' && ARGV.size == 1
        MacBuildBudget.advise(*ARGV)
      end
    RUBY
    File.write(File.join(@scripts, 'prepare_onnxruntime_macos.rb'), <<~RUBY)
      File.open(ENV.fetch('FIXTURE_EVENTS'), 'a') { |file| file.puts('prepare') }
      exit 23
    RUBY
    File.write(File.join(@bin, 'mise'), <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      abort 'Unexpected mise invocation' unless ARGV.shift(2) == ['exec', '--']
      if ARGV.first == 'ruby'
        ARGV.shift
        exec #{RbConfig.ruby.inspect}, *ARGV
      end
      File.open(ENV.fetch('FIXTURE_LOCK'), 'a+') do |file|
        exit 97 if file.flock(File::LOCK_EX | File::LOCK_NB)
      end
      File.open(ENV.fetch('FIXTURE_EVENTS'), 'a') do |file|
        file.puts(JSON.generate({ argv: ARGV, cwd: Dir.pwd }))
      end
      exit Integer(ENV.fetch('FIXTURE_CHILD_EXIT', '23'))
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'mise'))
    @environment = {
      'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'FIXTURE_LOCK' => @lock,
      'FIXTURE_EVENTS' => @events, 'FIXTURE_STORAGE_BLOCKED' => '0',
      'EPUB_NATIVE_LEASE_FD' => nil, 'EPUB_NATIVE_LEASE_PATH' => nil
    }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(driver, environment = {}, supervised: false)
    file = File.join(@scripts, driver)
    command = driver.end_with?('.sh') ? ['/bin/bash', file] : [RbConfig.ruby, file]
    command.concat(DRIVERS.fetch(driver))
    command = [RbConfig.ruby, File.join(@scripts, 'native_job.rb'), 'build', '--', *command] if supervised
    Open3.capture3(@environment.merge(environment), *command, chdir: @directory)
  end

  def test_forged_inherited_descriptor_never_bypasses_entrypoints
    DRIVERS.each_key do |driver|
      output, error, status = invoke(driver, { 'EPUB_NATIVE_LEASE_FD' => '999999',
                                             'EPUB_NATIVE_LEASE_PATH' => @lock })
      assert_equal 75, status.exitstatus, "#{driver}: #{output}#{error}"
      refute File.exist?(@events), "#{driver} accepted forged inherited metadata"
    end
  end

  def test_low_storage_is_a_note_and_every_driver_still_starts_its_work
    DRIVERS.each_key do |driver|
      File.unlink(@events) if File.exist?(@events)
      output, error, status = invoke(driver, { 'FIXTURE_STORAGE_BLOCKED' => '1' })
      assert_includes error, 'advisory, not a refusal: Fixture: build storage budget exceeded', "#{driver}: #{output}#{error}"
      # Only the Flutter desktop driver can run to its child in this fixture checkout;
      # the others end at a tool or helper the fixture does not provide, never at the note.
      next unless driver == 'build_flutter_desktop.rb'

      assert File.exist?(@events), "#{driver} was stopped by a storage note: #{output}#{error}"
      assert_equal 23, status.exitstatus, "#{driver}: #{output}#{error}"
    end
  end

  def test_drivers_note_each_full_output_volume_and_keep_going
    {
      'build_converter_ffi_android.rb' => %w[target/piper-android target/espeak-data],
      'build_flutter_android.rb' => %w[flutter_app/build],
      'build_flutter_desktop.rb' => %w[flutter_app/build]
    }.each do |driver, destinations|
      destinations.each do |destination|
        volume = File.join(@directory, destination)
        File.unlink(@events) if File.exist?(@events)
        _, error, status = invoke(driver, { 'FIXTURE_FULL_VOLUME' => volume })
        assert_includes error, 'destination volume is full', "#{driver}: #{error}"
        refute_equal 75, status.exitstatus, "#{driver}: #{error}"
      end
    end
  end

  def test_flutter_tasks_note_a_full_output_volume_and_keep_going
    %w[flutter:run flutter:run-desktop flutter:test native-tts:android:test].each do |name|
      metadata, error, status = Open3.capture3('mise', 'tasks', 'info', name, '--json', chdir: ROOT)
      assert status.success?, error
      body = JSON.parse(metadata).fetch('run').join("\n")
      environment = @environment.merge('FIXTURE_FULL_VOLUME' => File.join(@directory, 'flutter_app/build'))
      _, error, status = Open3.capture3(environment, '/bin/bash', '-euo', 'pipefail', '-c', body, chdir: @directory)
      assert_includes error, 'destination volume is full', "#{name}: #{error}" unless name == 'native-tts:android:test'
      refute_equal 75, status.exitstatus, "#{name}: #{error}"
    end
  end

  def test_command_frontend_preserves_literal_argv_failure_and_parent_lease
    child = File.join(@directory, 'literal child.rb')
    File.write(child, <<~RUBY)
      require_relative 'scripts/native_job'
      NativeJob.build_entrypoint(__FILE__, ARGV)
      File.open(ENV.fetch('FIXTURE_LOCK'), 'a+') { |file| exit 97 if file.flock(File::LOCK_EX | File::LOCK_NB) }
      puts ARGV.inspect
      exit 29
    RUBY
    command = [RbConfig.ruby, File.join(@scripts, 'native_build_command.rb'), '--',
               RbConfig.ruby, child, 'literal space', '$not-expanded', '--model=pt_BR-faber-medium']
    output, error, status = Open3.capture3(@environment, *command, chdir: @directory)
    assert_equal 29, status.exitstatus, "#{output}#{error}"
    assert_equal ['literal space', '$not-expanded', '--model=pt_BR-faber-medium'].inspect, output.strip
    output, error, status = Open3.capture3(@environment.merge('FIXTURE_STORAGE_BLOCKED' => '1'),
                                         *command, chdir: @directory)
    assert_equal 29, status.exitstatus, "a storage note never stops the child: #{output}#{error}"
    assert_includes error, 'advisory, not a refusal'
  end

  def test_clean_desktop_build_preserves_child_failure_and_real_lease
    output, error, status = invoke('build_flutter_desktop.rb')
    assert_equal 23, status.exitstatus, "#{output}#{error}"
    event = JSON.parse(File.read(@events))
    assert_equal %w[flutter build linux --release], event.fetch('argv')
    assert_equal File.join(@directory, 'flutter_app'), event.fetch('cwd')
  end

  def test_authenticated_parent_lease_does_not_trigger_a_second_lock
    output, error, status = invoke('build_flutter_desktop.rb', {}, supervised: true)
    assert_equal 23, status.exitstatus, "#{output}#{error}"
    assert_equal 1, File.readlines(@events).length
  end

  def test_clean_success_releases_the_original_lease
    output, error, status = invoke('build_flutter_desktop.rb', { 'FIXTURE_CHILD_EXIT' => '0' })
    assert status.success?, "#{output}#{error}"
    File.open(@lock, 'a+') { |file| assert file.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def stub_android_packager
    File.write(File.join(@scripts, 'package_converter_ffi_android.rb'), <<~RUBY)
      require 'json'
      require_relative 'native_job'
      NativeJob.lease(NativeJob::LOCK_PATH)
      File.open(ENV.fetch('FIXTURE_EVENTS'), 'a') do |file|
        file.puts(JSON.generate({ argv: ['packager', *ARGV], cwd: Dir.pwd }))
      end
    RUBY
  end

  def test_android_build_regenerates_plugin_registration_for_each_build_mode
    stub_android_packager
    %w[debug release].each do |mode|
      File.unlink(@events) if File.exist?(@events)
      output, error, status = Open3.capture3(@environment.merge('FIXTURE_CHILD_EXIT' => '0'),
        RbConfig.ruby, File.join(@scripts, 'build_flutter_android.rb'), mode, chdir: @directory)
      assert status.success?, "#{output}#{error}"
      events = File.readlines(@events).map { |line| JSON.parse(line).fetch('argv') }
      assert_equal 3, events.length
      assert_equal %w[packager --audit], events.first
      # Flutter must refresh platform tooling with the actual build mode;
      # a separate pub get plus --no-pub retains debug-only plugin registration.
      assert_equal ['flutter', 'build', 'apk', "--#{mode}", '--target-platform', 'android-arm64'], events[1]
      assert_equal ['packager', '--audit', '--apk', File.join(@directory, 'flutter_app/build/app/outputs/flutter-apk', "app-#{mode}.apk")], events.last
    end
  end

  def test_failed_android_build_preserves_status_and_skips_final_apk_audit
    stub_android_packager
    output, error, status = invoke('build_flutter_android.rb')
    assert_equal 23, status.exitstatus, "#{output}#{error}"
    events = File.readlines(@events).map { |line| JSON.parse(line).fetch('argv') }
    assert_equal 2, events.length
    assert_equal %w[flutter build apk --debug --target-platform android-arm64], events.last
  end

  def test_actual_native_task_bodies_still_enter_the_supervisor_and_only_note_low_storage
    %w[converter-ffi:build converter-ffi:build:local native-tts:rust:test converter-ffi:ios-device native-tts:android:test onnxruntime:host].each do |name|
      metadata, error, status = Open3.capture3('mise', 'tasks', 'info', name, '--json', chdir: ROOT)
      assert status.success?, error
      body = JSON.parse(metadata).fetch('run').join("\n")
      File.unlink(@events) if File.exist?(@events)
      output, error, = Open3.capture3(@environment.merge('FIXTURE_STORAGE_BLOCKED' => '1'),
                                      '/bin/bash', '-euo', 'pipefail', '-c', body, chdir: @directory)
      next if name == 'onnxruntime:host' && !RUBY_PLATFORM.include?('darwin')

      assert_includes error, 'advisory, not a refusal: Fixture: build storage budget exceeded', "#{name}: #{output}#{error}"
    end
  end

  def test_system_and_popen_forward_authenticated_lease_to_real_runtime_installers
    child = File.join(@directory, 'runtime-child.rb')
    File.write(child, <<~RUBY)
      require_relative 'scripts/fetch_onnxruntime_macos'
      require_relative 'scripts/fetch_onnxruntime_android'
      def PrebuiltOnnxRuntime.validate; raise 'fixture missing runtime'; end
      def AndroidOnnxRuntime.validate; raise 'fixture missing runtime'; end
      module NativeJob
        class << self
          alias fixture_original_lease lease
          def lease(path)
            fixture_original_lease(path)
            puts 'lease-ok'
            raise 'fixture authenticated lease reached'
          end
        end
      end
      begin
        ARGV.first == 'macos' ? PrebuiltOnnxRuntime.install : AndroidOnnxRuntime.ensure_runtime(already_locked: true)
      rescue StandardError => error
        exit(error.message == 'fixture authenticated lease reached' ? 0 : 91)
      end
      exit 92
    RUBY
    parent = File.join(@directory, 'runtime-parent.rb')
    File.write(parent, <<~RUBY)
      require_relative 'scripts/native_job'
      NativeJob.build_entrypoint(__FILE__, ARGV)
      %w[macos android].each do |platform|
        options = { close_others: true }.merge(NativeJob.child_options)
        text = IO.popen([#{RbConfig.ruby.inspect}, #{child.inspect}, platform], options, &:read)
        exit 93 unless $?.success? && text == "lease-ok\\n"
        exit 94 unless system(#{RbConfig.ruby.inspect}, #{child.inspect}, platform, **options)
      end
    RUBY
    output, error, status = Open3.capture3(@environment, RbConfig.ruby, parent, chdir: @directory)
    assert status.success?, "#{output}#{error}"
    assert_equal ["lease-ok", "lease-ok"], output.lines.map(&:strip)
    refute File.exist?(File.join(@directory, 'target')), 'Fixture must stop before download/extraction'
  end

  def test_external_cancellation_stops_the_entire_nested_command_tree
    paths = %w[driver frontend leaf].to_h { |name| [name, File.join(@directory, "#{name}.pid")] }
    leaf = File.join(@directory, 'ignores-term.rb')
    File.write(leaf, <<~RUBY)
      Signal.trap('TERM') {}
      File.write(#{paths.fetch('leaf').inspect}, Process.pid)
      loop { sleep 0.05 }
    RUBY
    frontend = File.join(@directory, 'record-frontend.rb')
    File.write(frontend, <<~RUBY)
      File.write(#{paths.fetch('frontend').inspect}, Process.pid)
      load #{File.join(@scripts, 'native_build_command.rb').inspect}
    RUBY
    driver = File.join(@directory, 'nested-driver.rb')
    File.write(driver, <<~RUBY)
      require_relative 'scripts/native_job'
      NativeJob.build_entrypoint(__FILE__, ARGV)
      File.write(#{paths.fetch('driver').inspect}, Process.pid)
      success = system(#{RbConfig.ruby.inspect}, #{frontend.inspect}, '--',
                       #{RbConfig.ruby.inspect}, #{leaf.inspect}, **NativeJob.child_options)
      exit(success ? 0 : ($?.exitstatus || 1))
    RUBY
    log = File.join(@directory, 'cancellation.log')
    pid = nil
    File.open(log, 'w') do |output|
      pid = Process.spawn(@environment, RbConfig.ruby, File.join(@scripts, 'native_job.rb'),
                          'build', '--', RbConfig.ruby, driver, out: output, err: output)
      Timeout.timeout(5) { sleep 0.02 until paths.values.all? { |path| File.file?(path) && !File.zero?(path) } }
      descendants = paths.transform_values { |path| Integer(File.read(path)) }
      Process.kill('TERM', pid) # Signal only the outer supervisor.
      _, status = Timeout.timeout(8) { Process.waitpid2(pid) }
      assert_equal 143, status.exitstatus, File.read(log)
      descendants.each do |name, child|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        while fixture_process_running?(child) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.02
        end
        refute fixture_process_running?(child), "#{name} survived external cancellation: #{File.read(log)}"
      end
      File.open(@lock, 'a+') { |file| assert file.flock(File::LOCK_EX | File::LOCK_NB), 'Cancelled descendant retained lease' }
    ensure
      # Always remove only this fixture's recorded processes, even after a RED.
      paths.each_value do |path|
        next unless File.file?(path) && !File.zero?(path)

        Process.kill('KILL', Integer(File.read(path))) rescue Errno::ESRCH
      end
      Process.kill('KILL', pid) rescue Errno::ESRCH if pid
      Process.waitpid(pid) rescue Errno::ECHILD if pid
    end
  end

  # No network: the transfer, checksum, clock and sleeper are injected.
  def android_download(statuses:, bodies: {}, good: 'pinned', **options)
    require_relative 'fetch_onnxruntime_android'
    Dir.mktmpdir('android-ort-download-') do |root|
      archive = File.join(root, 'runtime.aar')
      calls = []
      delays = []
      now = 0.0
      runner = lambda do |path, url, max_time|
        assert_operator max_time, :<=, AndroidOnnxRuntime::ATTEMPT_MAX_SECONDS
        assert_operator max_time, :>=, 1
        assert_equal archive, path
        refute File.exist?(path), 'A previous attempt must not leave its file behind'
        calls << url
        status = statuses.call(url, calls.size)
        File.write(path, bodies.fetch(url, good)) if status&.zero?
        now += 1
        status
      end
      verifier = ->(path) { File.read(path) == good }
      ok = AndroidOnnxRuntime.download(archive, sleeper: ->(seconds) { delays << seconds; now += seconds }, runner: runner,
                                       verifier: verifier, clock: -> { now }, **options)
      { ok: ok, calls: calls, delays: delays, kept: File.exist?(archive) && File.read(archive) }
    end
  end

  def test_android_runtime_download_falls_back_to_mirrors_of_the_same_pinned_path
    require_relative 'fetch_onnxruntime_android'
    urls = AndroidOnnxRuntime::MIRROR_URLS
    path = URI(AndroidOnnxRuntime::URL).path
    assert_equal urls.first, AndroidOnnxRuntime::URL, 'The canonical host is tried first and stays in the manifest'
    assert_equal %w[repo.maven.apache.org maven-central.storage-download.googleapis.com], urls.first(2).map { |url| URI(url).host },
      'An independent mirror follows the canonical CDN'
    urls.each { |url| assert_equal path, URI(url).path, url; assert_equal 'https', URI(url).scheme }

    # Observed: the canonical host answers 404 for every attempt.
    first_down = ->(url, _) { url == urls.first ? 22 : 0 }
    result = android_download(statuses: first_down)
    assert result[:ok]
    assert_equal urls.first(2), result[:calls]
    assert_equal [], result[:delays]

    # A mirror with the wrong body is rejected; the next one with the pinned body is accepted.
    result = android_download(statuses: first_down, bodies: { urls[1] => 'tampered' })
    assert result[:ok]
    assert_equal urls.first(3), result[:calls]
    assert_equal 'pinned', result[:kept]

    # Every mirror wrong or down: bounded rounds with backoff, then failure and no archive left.
    result = android_download(statuses: ->(url, _) { url == urls.last ? 0 : 22 }, bodies: { urls.last => 'tampered' })
    refute result[:ok]
    assert_equal urls * AndroidOnnxRuntime::DOWNLOAD_ROUNDS, result[:calls]
    assert_equal [10, 30], result[:delays]
    assert_equal false, result[:kept]

    # A transient same-host failure still recovers on a later round.
    result = android_download(statuses: ->(_, call) { call <= urls.size ? 22 : 0 })
    assert result[:ok]
    assert_equal urls + [urls.first], result[:calls]
    assert_equal [10], result[:delays]
  end

  def test_android_runtime_download_stops_on_permanent_failures_and_at_the_deadline
    require_relative 'fetch_onnxruntime_android'
    [nil, 2, 3, 23, 26, 27].each do |status|
      result = android_download(statuses: ->(_, _) { status })
      refute result[:ok]
      assert_equal 1, result[:calls].size, "Local curl status #{status.inspect} is not retried on other hosts"
    end
    # Host-specific failures (HTTP/2 92, framing 16, send 55, TLS 60, redirects 47, size cap 63) reach the next mirror.
    [16, 47, 55, 60, 63, 92].each do |status|
      result = android_download(statuses: ->(url, _) { url == AndroidOnnxRuntime::URL ? status : 0 })
      assert result[:ok], "curl status #{status} on one host must fall back"
      assert_equal 2, result[:calls].size
    end
    result = android_download(statuses: ->(_, _) { 28 }, deadline: 3)
    refute result[:ok]
    assert_equal 3, result[:calls].size, 'No attempt starts after the deadline'
    result = android_download(statuses: ->(_, _) { 28 }, deadline: 12)
    refute result[:ok]
    assert_equal AndroidOnnxRuntime::MIRROR_URLS.size, result[:calls].size, 'No backoff that would cross the deadline'
    assert_equal [], result[:delays]
times = []
AndroidOnnxRuntime.download(File.join(Dir.tmpdir, "ort-deadline-#{Process.pid}.aar"), deadline: 50, sleeper: ->(_) {},
  runner: ->(_, _, max_time) { times << max_time; 28 }, verifier: ->(_) { false }, clock: -> { 0.0 + times.sum })
assert_equal [50], times, 'An attempt never runs past the wall-clock deadline'
  end

  def test_android_runtime_download_keeps_the_pinned_curl_contract
    require_relative 'fetch_onnxruntime_android'
    Dir.mktmpdir('android-ort-curl-') do |root|
      trace = File.join(root, 'argv')
      File.write(File.join(root, 'curl'), "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"#{trace}\"\nexit 22\n")
      File.chmod(0o700, File.join(root, 'curl'))
      mirror = AndroidOnnxRuntime::MIRROR_URLS[1]
      script = "require #{File.join(ROOT, 'scripts/fetch_onnxruntime_android').inspect}; print AndroidOnnxRuntime.curl(ARGV.fetch(0), ARGV.fetch(1))"
      output, error, status = Open3.capture3({ 'PATH' => "#{root}:#{ENV.fetch('PATH')}" }, RbConfig.ruby, '-e', script, File.join(root, 'a.aar'), mirror)
      assert status.success?, error
      assert_equal '22', output
      argv = File.readlines(trace, chomp: true)
      %w[--fail --location --max-filesize --output].each { |flag| assert_includes argv, flag }
      assert_equal '=https', argv[argv.index('--proto') + 1]
      assert_equal '=https', argv[argv.index('--proto-redir') + 1]
      assert_equal mirror, argv.last
      assert_equal AndroidOnnxRuntime::ARCHIVE_SIZE.to_s, argv[argv.index('--max-filesize') + 1]
      assert_equal '120', argv[argv.index('--max-time') + 1]
      refute_includes argv, '--retry'
    end
  end

  def fixture_process_running?(pid)
    Process.kill(0, pid)
    state, = Open3.capture2('ps', '-o', 'stat=', '-p', pid.to_s)
    !state.strip.empty? && !state.strip.start_with?('Z')
  rescue Errno::ESRCH
    false
  end
end
