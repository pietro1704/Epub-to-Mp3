# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'json'
require 'timeout'

# Real drivers/supervisor, isolated preflight and real child processes; no native
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
    'build_onnxruntime_macos.sh' => []
  }.freeze
  BENCHMARKS = %w[build-edge.rb build-pocket.rb run.rb].freeze

  def setup
    @directory = Dir.mktmpdir('native Faber entrypoints ')
    @scripts = File.join(@directory, 'scripts')
    @bin = File.join(@directory, 'bin')
    @lock = File.join(@directory, 'lease')
    @events = File.join(@directory, 'events')
    FileUtils.mkdir_p([@scripts, @bin, File.join(@directory, 'flutter_app')])
    benchmark_directory = File.join(@directory, 'docs/research/tts-phone-benchmark')
    FileUtils.mkdir_p(benchmark_directory)
    BENCHMARKS.each do |name|
      FileUtils.cp(File.join(ROOT, 'docs/research/tts-phone-benchmark', name), benchmark_directory)
    end
    (DRIVERS.keys + %w[native_job.rb native_build_command.rb fetch_onnxruntime_android.rb fetch_onnxruntime_macos.rb]).each do |name|
      content = File.read(File.join(ROOT, 'scripts', name))
      content = content.gsub('/tmp/epub2mp3.heavy-job.lock', @lock)
      File.write(File.join(@scripts, name), content)
    end
    File.write(File.join(@scripts, 'native_build_preflight.rb'), <<~RUBY)
      module NativeBuildPreflight
        def self.check
          'Fixture: Simulator is booted' if ENV['FIXTURE_BLOCKED'] == '1'
        end
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
      'FIXTURE_EVENTS' => @events, 'FIXTURE_BLOCKED' => '0',
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

  def test_blocked_preflight_precedes_every_preparation_or_compiler
    DRIVERS.each_key do |driver|
      output, error, status = invoke(driver, { 'FIXTURE_BLOCKED' => '1' })
      assert_equal 75, status.exitstatus, "#{driver}: #{output}#{error}"
      refute File.exist?(@events), "#{driver} started preparation or a compiler"
    end
  end

  def test_forged_inherited_descriptor_never_bypasses_entrypoints
    DRIVERS.each_key do |driver|
      output, error, status = invoke(driver, { 'EPUB_NATIVE_LEASE_FD' => '999999',
                                             'EPUB_NATIVE_LEASE_PATH' => @lock })
      assert_equal 75, status.exitstatus, "#{driver}: #{output}#{error}"
      refute File.exist?(@events), "#{driver} accepted forged inherited metadata"
    end
  end

  def test_benchmark_drivers_refuse_before_preparation_or_device_actions
    BENCHMARKS.each do |name|
      file = File.join(@directory, 'docs/research/tts-phone-benchmark', name)
      output, error, status = Open3.capture3(@environment.merge('FIXTURE_BLOCKED' => '1'),
                                           RbConfig.ruby, file, chdir: @directory)
      assert_equal 75, status.exitstatus, "#{name}: #{output}#{error}"
      refute File.exist?(File.join(@directory, '.reports')), "#{name} started preparation"
      refute File.exist?(@events), "#{name} started a compiler or device action"
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
    output, error, status = Open3.capture3(@environment.merge('FIXTURE_BLOCKED' => '1'),
                                         *command, chdir: @directory)
    assert_equal 75, status.exitstatus, "#{output}#{error}"
    assert_empty output
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

  def test_actual_native_task_bodies_refuse_before_preparation
    %w[converter-ffi:build native-tts:rust:test tts:web:verify converter-ffi:ios-device native-tts:android:test onnxruntime:host].each do |name|
      metadata, error, status = Open3.capture3('mise', 'tasks', 'info', name, '--json', chdir: ROOT)
      assert status.success?, error
      body = JSON.parse(metadata).fetch('run').join("\n")
      output, error, status = Open3.capture3(@environment.merge('FIXTURE_BLOCKED' => '1'),
                                           '/bin/bash', '-euo', 'pipefail', '-c', body, chdir: @directory)
      expected = name == 'onnxruntime:host' && !RUBY_PLATFORM.include?('darwin') ? 0 : 75
      assert_equal expected, status.exitstatus, "#{name}: #{output}#{error}"
      refute File.exist?(@events), "#{name} started preparation or a compiler"
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

  def fixture_process_running?(pid)
    Process.kill(0, pid)
    state, = Open3.capture2('ps', '-o', 'stat=', '-p', pid.to_s)
    !state.strip.empty? && !state.strip.start_with?('Z')
  rescue Errno::ESRCH
    false
  end
end
