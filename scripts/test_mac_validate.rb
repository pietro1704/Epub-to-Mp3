# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'mac_validate'

class MacValidateTest < Minitest::Test
  def setup
    @temporary = Dir.mktmpdir('mac validation with spaces ')
    @root = File.join(@temporary, 'checkout')
    @derived = File.join(@temporary, 'existing DerivedData')
    @app = File.join(@derived, 'Build/Products/Debug/EpubToMp3.app')
    @bin = File.join(@temporary, 'bin')
    @trace = File.join(@temporary, 'trace')
    FileUtils.mkdir_p([File.join(@root, 'ios/EpubToMp3/EpubToMp3'), File.join(@root, 'target/release'),
                       File.join(@app, 'Contents/MacOS'), @bin])
    File.write(File.join(@root, 'ios/EpubToMp3/EpubToMp3/App.swift'), 'source')
    File.write(File.join(@root, 'target/release/libconverter_ffi.dylib'), 'ffi')
    %w[Cargo.toml Cargo.lock].each { |name| File.write(File.join(@root, name), name) }
    File.write(File.join(@app, 'Contents/MacOS/EpubToMp3'), 'app')
    %w[xcode-select xcodebuild uname codesign open xcrun pgrep].each do |name|
      File.write(File.join(@bin, name), <<~SH)
        #!/bin/sh
        echo '#{name}' "$@" >> "$MAC_VALIDATE_TEST_TRACE"
        case '#{name}' in
          xcode-select) echo /Applications/Xcode.app/Contents/Developer ;;
          xcodebuild) [ "$1" = -version ] || exit 88; echo Xcode-fixture ;;
          uname) echo x86_64 ;;
          xcrun) echo '{"devices":{}}' ;;
          pgrep) exit 1 ;;
        esac
      SH
      File.chmod(0o755, File.join(@bin, name))
    end
    @environment = { 'PATH' => "#{@bin}:/usr/bin:/bin", 'MAC_VALIDATE_TEST_TRACE' => @trace }
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def invoke(mode, *extra)
    Open3.capture3(@environment, RbConfig.ruby, File.join(__dir__, 'mac_validate.rb'), mode,
                  '--project-root', @root, '--derived-data', @derived, *extra)
  end

  def with_environment
    previous = @environment.to_h { |key, _| [key, ENV[key]] }
    @environment.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def receipt
    with_environment do
      File.write(File.join(@derived, 'mac-validation-Debug.json'), JSON.generate(
        'identity' => MacValidate.identity(@root, 'Debug'), 'products' => MacValidate.product_hashes(@app)))
    end
  end

  def test_inspection_of_legacy_product_is_read_only_and_does_not_build
    out, error, status = invoke('inspect')
    assert status.success?, error
    assert_equal false, JSON.parse(out).fetch('compatible')
    refute File.exist?(File.join(@derived, 'mac-validation-Debug.json'))
    refute_match(/open|codesign|build$/, File.read(@trace))
  end

  def test_verified_product_launches_normal_gui_without_compilation
    receipt
    _out, error, status = invoke('gui')
    assert status.success?, error
    assert_includes File.read(@trace), "open #{@app}"
    refute_includes File.read(@trace), '-jobs'
  end

  def test_changed_source_binary_configuration_and_flags_each_refuse_gui
    changes = [
      -> { File.write(File.join(@root, 'ios/EpubToMp3/EpubToMp3/App.swift'), 'changed') },
      -> { File.write(File.join(@app, 'Contents/MacOS/EpubToMp3'), 'changed') },
      -> { @environment['OTHER_SWIFT_FLAGS'] = '-Ounchecked' },
      -> { File.write(File.join(@root, 'Cargo.lock'), 'changed') },
      -> { File.write(File.join(@bin, 'xcode-select'), "#!/bin/sh\necho /Different/Xcode\n") }
    ]
    changes.each do |change|
      receipt
      FileUtils.rm_f(@trace)
      change.call
      _out, error, status = invoke('gui')
      refute status.success?
      assert_includes error, 'identity unknown or changed'
      refute_includes File.read(@trace), 'open '
    end
    receipt
    _out, error, status = invoke('gui', '--configuration', 'Release')
    refute status.success?
    assert_includes error, 'identity unknown or changed'
  end

  def test_test_and_instruction_changes_do_not_invalidate_production_receipt
    receipt
    FileUtils.mkdir_p(File.join(@root, 'ios/EpubToMp3/EpubToMp3Tests'))
    File.write(File.join(@root, 'ios/EpubToMp3/EpubToMp3Tests/NewTest.swift'), 'new test')
    File.write(File.join(@root, 'ios/EpubToMp3/AGENTS.md'), 'local rules')
    out, error, status = invoke('inspect')
    assert status.success?, error
    assert_equal true, JSON.parse(out).fetch('compatible')
  end

  def test_changed_cached_runtime_invalidates_gui_identity_without_downloading
    runtime = File.join(@root, 'target/onnxruntime-macos-prebuilt/x86_64/lib/libonnxruntime.dylib')
    FileUtils.mkdir_p(File.dirname(runtime))
    File.write(runtime, 'original cached runtime')
    receipt
    FileUtils.rm_f(@trace)
    File.write(runtime, 'changed cached runtime')
    _out, error, status = invoke('gui')
    refute status.success?
    assert_includes error, 'identity unknown or changed'
    refute_includes File.read(@trace), 'open '
  end

  def test_signature_failure_prevents_gui_launch
    receipt
    FileUtils.rm_f(@trace)
    File.write(File.join(@bin, 'codesign'), "#!/bin/sh\nexit 42\n")
    _out, error, status = invoke('gui')
    refute status.success?
    assert_includes error, 'codesign failed'
    refute_includes File.read(@trace), 'open '
  end

  def test_running_simulator_prevents_gui_launch_without_stopping_user_processes
    receipt
    FileUtils.rm_f(@trace)
    File.write(File.join(@bin, 'xcrun'), "#!/bin/sh\necho '{\"devices\":{\"iOS\":[{\"state\":\"Booted\"}]}}'\n")
    _out, error, status = invoke('gui')
    if RUBY_PLATFORM.match?(/(?:x86_64|i386).*darwin/)
      refute status.success?
      assert_includes error, 'GUI launch refused'
      refute_includes File.read(@trace), 'open '
    else
      assert status.success?, error
    end
  end

  def test_failed_guard_stops_build_without_writing_receipt
    with_environment do
      [75, 143].each do |exit_code|
        captured = nil
        original = NativeJob.method(:run)
        NativeJob.define_singleton_method(:run) { |**options| captured = options; exit_code }
        begin
          assert_equal exit_code, MacValidate.main(['build', '--project-root', @root, '--derived-data', @derived])
        ensure
          NativeJob.define_singleton_method(:run, original)
        end
        assert_equal 'build', captured.fetch(:phase)
        assert_equal '_build', captured.fetch(:command)[2]
        assert_equal [File.realpath(@root), @derived, 'Debug'], captured.fetch(:command).drop(3)
        refute File.exist?(File.join(@derived, 'mac-validation-Debug.json'))
      end
    end
  end

  def test_incompatible_packaging_checkout_is_rejected_before_mutation
    FileUtils.mkdir_p(File.join(@root, 'scripts'))
    File.write(File.join(@root, 'scripts/bundle_onnxruntime_apple.sh'), 'wrong script')
    FileUtils.mkdir_p(File.join(@app, 'Contents/Frameworks'))
    ffi = File.join(@app, 'Contents/Frameworks/libconverter_ffi.dylib')
    File.write(ffi, 'original')
    _out, error, status = invoke('package')
    refute status.success?
    assert_includes error, 'bundler differs'
    assert_equal 'original', File.read(ffi)
    refute_includes File.read(@trace), 'codesign'
  end
end
