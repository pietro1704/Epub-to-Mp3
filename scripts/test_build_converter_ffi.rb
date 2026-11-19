# frozen_string_literal: true

# Host-only coverage for build_converter_ffi.rb and validate_converter_ffi_targets.rb.
# Build-mode cases use fake `cargo`/`rustup` executables on an isolated PATH;
# no compiler or toolchain is ever invoked.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "build_converter_ffi"

class BuildConverterFfiTest < Minitest::Test
  SCRIPTS = File.expand_path(__dir__)
  COPIED = %w[build_converter_ffi.rb validate_converter_ffi_targets.rb python_cli_compat.rb].freeze
  ALL = %w[android-arm64 android-armv7 android-x64 android-x86 ios-device ios-simulator-arm64 ios-simulator-x64].freeze
  RUST = {
    "android-arm64" => "aarch64-linux-android", "android-armv7" => "armv7-linux-androideabi",
    "android-x64" => "x86_64-linux-android", "android-x86" => "i686-linux-android", "ios-device" => "aarch64-apple-ios",
    "ios-simulator-arm64" => "aarch64-apple-ios-sim", "ios-simulator-x64" => "x86_64-apple-ios"
  }.freeze
  METAVAR = "{#{ALL.join(",")}}"
  USAGE = "usage: build_converter_ffi.rb [-h] [--list] [--dry-run]\n#{" " * 30}[#{METAVAR} ...]\n"

  def setup
    @root = File.realpath(Dir.mktmpdir("converter ffi fixture "))
    FileUtils.mkdir_p(File.join(@root, "scripts"))
    COPIED.each { |name| FileUtils.cp(File.join(SCRIPTS, name), File.join(@root, "scripts", name)) }
    @bin = File.join(@root, "fake-bin")
    FileUtils.mkdir_p(@bin)
    @cargo_log = File.join(@root, "cargo.log")
    @rustup_log = File.join(@root, "rustup.log")
    fake("rustup", <<~SH)
      printf '%s\\n' "$*" >> "$RUSTUP_LOG"
      [ -n "$RUSTUP_EXIT" ] && exit "$RUSTUP_EXIT"
      printf '%s\\n' $RUSTUP_INSTALLED
    SH
    @environment = { "PATH" => "#{@bin}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "HOME" => @root,
                     "CARGO_LOG" => @cargo_log, "RUSTUP_LOG" => @rustup_log, "RUSTUP_INSTALLED" => RUST.values.join(" ") }
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def fake(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
  end

  def install_fake_cargo
    fake("cargo", <<~SH)
      printf '%s|%s\\n' "$PWD" "$*" >> "$CARGO_LOG"
      [ -n "$CARGO_EXIT" ] && exit "$CARGO_EXIT"
      [ -n "$CARGO_SKIP_ARTIFACT" ] && exit 0
      case "$4" in *apple*) library=libconverter_ffi.dylib ;; *) library=libconverter_ffi.so ;; esac
      mkdir -p "target/$4/release" && : > "target/$4/release/$library"
    SH
  end

  def run_script(*arguments, script: "build_converter_ffi.rb", environment: {})
    Open3.capture3(@environment.merge(environment), RbConfig.ruby, File.join(@root, "scripts", script), *arguments,
                   unsetenv_others: true, chdir: @root)
  end

  def log(path) = File.exist?(path) ? File.read(path).lines(chomp: true) : []

  def artifact(name)
    library = RUST.fetch(name).include?("apple") ? "libconverter_ffi.dylib" : "libconverter_ffi.so"
    "#{@root}/target/#{RUST.fetch(name)}/release/#{library}"
  end

  def list_line(name)
    abi = { "android-arm64" => "arm64-v8a", "android-armv7" => "armeabi-v7a", "android-x64" => "x86_64", "android-x86" => "x86" }[name]
    jni = abi ? " -> #{@root}/flutter_app/android/app/src/main/jniLibs/#{abi}/libconverter_ffi.so" : ""
    "#{name}: #{RUST.fetch(name)} -> #{artifact(name)}#{jni}\n"
  end

  def test_list_prints_every_mapping_in_declaration_order_without_toolchains
    stdout, stderr, status = run_script("--list")
    assert_equal([0, ""], [status.exitstatus, stderr])
    assert_equal(ALL.map { |name| list_line(name) }.join, stdout)
    assert_empty(log(@rustup_log))
    assert_empty(log(@cargo_log))
  end

  def test_list_ignores_selected_targets_but_still_validates_choices
    stdout, _stderr, status = run_script("ios-device", "--list")
    assert_equal([0, ALL.map { |name| list_line(name) }.join], [status.exitstatus, stdout])
    stdout, stderr, status = run_script("--list", "bogus")
    assert_equal([2, ""], [status.exitstatus, stdout])
    assert_equal("#{USAGE}build_converter_ffi.rb: error: argument targets: invalid choice: 'bogus' (choose from #{ALL.join(", ")})\n", stderr)
  end

  def test_list_resolves_symlinked_script_to_real_repository_root
    link = File.join(@root, "linked")
    FileUtils.mkdir_p(link)
    File.symlink(File.join(@root, "scripts/build_converter_ffi.rb"), File.join(link, "build_converter_ffi.rb"))
    stdout, _stderr, status = Open3.capture3(@environment, RbConfig.ruby, File.join(link, "build_converter_ffi.rb"), "--list",
                                             unsetenv_others: true)
    assert_equal(0, status.exitstatus)
    assert_equal(list_line("ios-device"), stdout.lines[4])
  end

  def test_argparse_errors_and_help
    _stdout, stderr, status = run_script("ios-device", "--list", "extra")
    assert_equal([2, "#{USAGE}build_converter_ffi.rb: error: unrecognized arguments: extra\n"], [status.exitstatus, stderr])
    _stdout, stderr, = run_script("--list=yes")
    assert_equal("#{USAGE}build_converter_ffi.rb: error: argument --list: ignored explicit argument 'yes'\n", stderr)
    _stdout, stderr, = run_script("--unknown")
    assert_equal("#{USAGE}build_converter_ffi.rb: error: unrecognized arguments: --unknown\n", stderr)
    stdout, stderr, status = run_script("-h")
    assert_equal([0, ""], [status.exitstatus, stderr])
    assert(stdout.start_with?("#{USAGE}\nBuild converter-ffi for explicitly requested native Rust targets. This script\n"))
    assert_includes(stdout, "\npositional arguments:\n  #{METAVAR}\n#{" " * 24}logical target names; defaults to all supported\n#{" " * 24}targets\n")
    assert(stdout.end_with?("  --dry-run             validate prerequisites and print cargo commands\n#{" " * 24}without building\n"))
  end

  def test_abbreviated_flags_select_dry_run
    install_fake_cargo
    stdout, _stderr, status = run_script("--dry", "ios-device")
    assert_equal(0, status.exitstatus)
    assert_equal("+ cargo build --release --target aarch64-apple-ios -p converter-ffi\noutput: #{artifact("ios-device")}\n", stdout)
  end

  def test_missing_cargo_fails_before_rustup
    stdout, stderr, status = run_script("ios-device")
    assert_equal([1, ""], [status.exitstatus, stdout])
    assert_equal("error: cargo is unavailable; install Rust via mise, then retry (this task does not install it)\n", stderr)
    assert_empty(log(@rustup_log))
  end

  def test_failing_rustup_is_reported
    install_fake_cargo
    _stdout, stderr, status = run_script("ios-device", environment: { "RUSTUP_EXIT" => "1" })
    assert_equal([1, "error: rustup is required to inspect installed targets; install it, then add targets manually\n"], [status.exitstatus, stderr])
    assert_equal(["target list --installed"], log(@rustup_log))
    assert_empty(log(@cargo_log))
  end

  def test_missing_rust_targets_are_listed_in_request_order
    install_fake_cargo
    _stdout, stderr, status = run_script("ios-device", "android-x86", "ios-simulator-x64", environment: { "RUSTUP_INSTALLED" => "aarch64-apple-ios" })
    assert_equal(1, status.exitstatus)
    assert_equal("error: required Rust target(s) are not installed: android-x86 (i686-linux-android), ios-simulator-x64 (x86_64-apple-ios). " \
                 "Add them explicitly with `rustup target add <target>`; this task will not download toolchains.\n", stderr)
    assert_empty(log(@cargo_log))
  end

  def test_dry_run_defaults_to_all_targets_without_invoking_cargo
    install_fake_cargo
    stdout, stderr, status = run_script("--dry-run")
    assert_equal([0, ""], [status.exitstatus, stderr])
    expected = ALL.map { |name| "+ cargo build --release --target #{RUST.fetch(name)} -p converter-ffi\noutput: #{artifact(name)}\n" }.join
    assert_equal(expected, stdout)
    assert_empty(log(@cargo_log))
  end

  def test_build_invokes_cargo_from_repository_root_and_checks_artifacts
    install_fake_cargo
    stdout, stderr, status = run_script("android-arm64", "ios-device", "android-arm64")
    assert_equal([0, ""], [status.exitstatus, stderr])
    commands = %w[android-arm64 ios-device android-arm64].map { |name| "build --release --target #{RUST.fetch(name)} -p converter-ffi" }
    assert_equal(commands.map { |command| "#{@root}|#{command}" }, log(@cargo_log))
    assert_equal(%w[android-arm64 ios-device android-arm64].map { |name| "+ cargo #{commands.first.sub(RUST["android-arm64"], RUST.fetch(name))}\noutput: #{artifact(name)}\n" }.join, stdout)
    assert(File.file?(artifact("ios-device")))
  end

  def test_cargo_failure_stops_the_build
    install_fake_cargo
    stdout, stderr, status = run_script("ios-device", "android-x86", environment: { "CARGO_EXIT" => "3" })
    assert_equal([1, "+ cargo build --release --target aarch64-apple-ios -p converter-ffi\n"], [status.exitstatus, stdout])
    assert_equal("error: cargo failed for ios-device (aarch64-apple-ios); install the target/toolchain manually and retry\n", stderr)
    assert_equal(1, log(@cargo_log).length)
  end

  def test_successful_cargo_without_artifact_is_rejected
    install_fake_cargo
    _stdout, stderr, status = run_script("android-x64", environment: { "CARGO_SKIP_ARTIFACT" => "1" })
    assert_equal([1, "error: cargo reported success but artifact is missing: #{artifact("android-x64")}\n"], [status.exitstatus, stderr])
  end

  def test_path_helpers_and_unknown_target_validation
    assert_equal("/r/target/x86_64-apple-ios/release/libconverter_ffi.dylib", BuildConverterFfi.artifact_path("/r", "ios-simulator-x64"))
    assert_equal("/r/flutter_app/android/app/src/main/jniLibs/x86/libconverter_ffi.so", BuildConverterFfi.android_jni_path("/r", "android-x86"))
    assert_equal("ios-device is not an Android target", assert_raises(ArgumentError) { BuildConverterFfi.android_jni_path("/r", "ios-device") }.message)
    assert_raises(KeyError) { BuildConverterFfi.artifact_path("/r", "bogus") }
    error = assert_raises(BuildConverterFfi::Failure) { BuildConverterFfi.validate_targets(%w[ios-device x y]) }
    assert_equal("error: unknown target name(s): x, y; choose from: #{ALL.join(", ")}", error.message)
  end

  def test_validator_accepts_the_shipped_mapping
    stdout, stderr, status = run_script(script: "validate_converter_ffi_targets.rb")
    assert_equal([0, "validated 7 converter-ffi target mappings\n", ""], [status.exitstatus, stdout, stderr])
  end

  def test_validator_rejects_a_changed_mapping
    path = File.join(@root, "scripts/build_converter_ffi.rb")
    File.write(path, File.read(path).sub('"ios-device" => "aarch64-apple-ios"', '"ios-device" => "aarch64-apple-darwin"'))
    stdout, stderr, status = run_script(script: "validate_converter_ffi_targets.rb")
    assert_equal([1, ""], [status.exitstatus, stdout])
    assert_equal("AssertionError: TARGETS mapping differs from the expected mapping\n", stderr)
  end

  def test_validator_rejects_a_changed_artifact_name
    path = File.join(@root, "scripts/build_converter_ffi.rb")
    File.write(path, File.read(path).sub('"libconverter_ffi.dylib"', '"libconverter_ffi.a"'))
    _stdout, stderr, status = run_script(script: "validate_converter_ffi_targets.rb")
    assert_equal([1, "AssertionError: artifact path for ios-device\n"], [status.exitstatus, stderr])
  end
end
