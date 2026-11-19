# frozen_string_literal: true

# Build converter-ffi for explicitly requested native Rust targets.
#
# This script never installs Rust toolchains or targets. It validates the target
# mapping first, checks that each target is already installed, then invokes
# `cargo build --release --target <target> -p converter-ffi`.

require "open3"
require_relative "python_cli_compat"

module BuildConverterFfi
  TARGETS = {
    "android-arm64" => "aarch64-linux-android",
    "android-armv7" => "armv7-linux-androideabi",
    "android-x64" => "x86_64-linux-android",
    "android-x86" => "i686-linux-android",
    "ios-device" => "aarch64-apple-ios",
    "ios-simulator-arm64" => "aarch64-apple-ios-sim",
    "ios-simulator-x64" => "x86_64-apple-ios"
  }.freeze

  ANDROID_JNI_ABIS = {
    "android-arm64" => "arm64-v8a",
    "android-armv7" => "armeabi-v7a",
    "android-x64" => "x86_64",
    "android-x86" => "x86"
  }.freeze

  PROG = "build_converter_ffi.rb"
  POSITIONAL_METAVAR = "{#{TARGETS.keys.sort.join(",")}}".freeze
  USAGE = <<~TEXT
    usage: #{PROG} [-h] [--list] [--dry-run]
                                  [#{POSITIONAL_METAVAR} ...]
  TEXT
  HELP = <<~TEXT
    #{USAGE}
    Build converter-ffi for explicitly requested native Rust targets. This script
    never installs Rust toolchains or targets. It validates the target mapping
    first, checks that each target is already installed, then invokes `cargo build
    --release --target <target> -p converter-ffi`.

    positional arguments:
      #{POSITIONAL_METAVAR}
                            logical target names; defaults to all supported
                            targets

    options:
      -h, --help            show this help message and exit
      --list                list logical names, Rust targets, and exact output
                            paths
      --dry-run             validate prerequisites and print cargo commands
                            without building
  TEXT

  # Raised where the Python script raised SystemExit(message): stderr + exit 1.
  class Failure < StandardError; end

  module_function

  def artifact_path(repo_root, name)
    target = TARGETS.fetch(name)
    library = if target.end_with?("windows-msvc") then "converter_ffi.dll"
              elsif target.include?("apple") then "libconverter_ffi.dylib"
              else "libconverter_ffi.so"
              end
    File.join(repo_root, "target", target, "release", library)
  end

  def android_jni_path(repo_root, name)
    raise ArgumentError, "#{name} is not an Android target" unless ANDROID_JNI_ABIS.key?(name)

    File.join(repo_root, "flutter_app", "android", "app", "src", "main", "jniLibs", ANDROID_JNI_ABIS.fetch(name), "libconverter_ffi.so")
  end

  def validate_targets(names)
    unknown = names.reject { |name| TARGETS.key?(name) }
    return if unknown.empty?

    raise Failure, "error: unknown target name(s): #{unknown.join(", ")}; choose from: #{TARGETS.keys.join(", ")}"
  end

  # shutil.which equivalent: first executable regular file named `command` on PATH.
  def which(command)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      candidate = File.join(directory.empty? ? "." : directory, command)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  def installed_targets
    stdout, _stderr, status = Open3.capture3("rustup", "target", "list", "--installed")
    raise Failure, "error: rustup is required to inspect installed targets; install it, then add targets manually" unless status.success?

    stdout.split
  end

  def parser
    PythonCliCompat::ArgumentParser.new(
      prog: PROG, usage: USAGE, help: HELP,
      options: { "--list" => { dest: :list, kind: :flag }, "--dry-run" => { dest: :dry_run, kind: :flag } },
      positional: { dest: :targets, choices: TARGETS.keys.sort }
    )
  end

  def main(argv = ARGV, repo_root: File.dirname(File.realpath(__FILE__), 2))
    args = parser.parse(argv)
    names = args[:targets].nil? || args[:targets].empty? ? TARGETS.keys : args[:targets]

    if args[:list]
      TARGETS.each do |name, target|
        destination = ANDROID_JNI_ABIS.key?(name) ? " -> #{android_jni_path(repo_root, name)}" : ""
        puts "#{name}: #{target} -> #{artifact_path(repo_root, name)}#{destination}"
      end
      return 0
    end

    validate_targets(names)
    raise Failure, "error: cargo is unavailable; install Rust via mise, then retry (this task does not install it)" if which("cargo").nil?

    installed = installed_targets
    missing = names.reject { |name| installed.include?(TARGETS.fetch(name)) }.map { |name| "#{name} (#{TARGETS.fetch(name)})" }
    unless missing.empty?
      raise Failure, "error: required Rust target(s) are not installed: #{missing.join(", ")}. " \
                     "Add them explicitly with `rustup target add <target>`; this task will not download toolchains."
    end

    names.each do |name|
      target = TARGETS.fetch(name)
      command = ["cargo", "build", "--release", "--target", target, "-p", "converter-ffi"]
      puts "+ #{command.join(" ")}"
      unless args[:dry_run]
        unless system(*command, chdir: repo_root)
          raise Failure, "error: cargo failed for #{name} (#{target}); install the target/toolchain manually and retry"
        end

        output = artifact_path(repo_root, name)
        raise Failure, "error: cargo reported success but artifact is missing: #{output}" unless File.file?(output)
      end
      puts "output: #{artifact_path(repo_root, name)}"
    end
    0
  rescue Failure => error
    $stdout.flush
    warn error.message
    1
  end
end

exit BuildConverterFfi.main if $PROGRAM_NAME == __FILE__
