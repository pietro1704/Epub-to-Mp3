#!/usr/bin/env ruby
# frozen_string_literal: true

# Local-only macOS converter-ffi build for the Debug app and test loop.
#
# It writes target/local-dev/release/libconverter_ffi.dylib: the release
# profile with local overrides passed through `--config`, in its own target
# directory below the checkout's shared target/. Cargo.toml, `[profile.release]`,
# target/release and every CI, packaging and release artifact stay unchanged;
# release-only consumers (packaging, mac:validate receipts, workflows) never
# read target/local-dev. A named custom profile is not used: the vendored
# espeak-rs-sys build script finds its output directory through PROFILE, which
# cargo reports as "release" for a custom profile inheriting release.
#
# The shared target/ is used by several worktrees. Cargo decides freshness of
# path packages by mtime, so a checkout whose edited files are older than the
# last build from another worktree can silently reuse that worktree's dylib.
# A content stamp next to the dylib records every path-package file it was
# built from: identical inputs skip cargo entirely (also across worktrees), and
# files whose content differs are touched so cargo's dep-info must notice them
# (this also covers files a crate includes from another package with #[path]).
require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/version"

module ConverterFfiLocalBuild
  TARGET_SUBDIRECTORY = "local-dev"
  # Measured on the Intel development Mac (see docs/agents/macos-validation.md):
  # release keeps codegen-units=1 and thin LTO. Locally, workspace crates build
  # incrementally at opt-level 0 without LTO (a converter-core edit fell from
  # 98 s to 14 s of cargo time), while dependencies keep opt-level 3 and
  # one codegen unit, which kept the cold build closest to release.
  PROFILE_SETTINGS = {
    "opt-level" => "0",
    "lto" => "false",
    "codegen-units" => "16",
    "incremental" => "true",
    "strip" => "false",
    'package."*".opt-level' => "3",
    'package."*".codegen-units' => "1"
  }.freeze
  LIBRARY = "libconverter_ffi.dylib"
  STAMP_VERSION = 2
  GLOBAL_INPUTS = %w[Cargo.toml Cargo.lock .cargo/config.toml rust-toolchain.toml].freeze

  module_function

  def profile_configs
    PROFILE_SETTINGS.map { |key, value| "profile.release.#{key}=#{value}" }
  end

  def local_target_dir(root)
    File.join(root, "target", TARGET_SUBDIRECTORY)
  end

  def cargo_command(root)
    ["cargo", *profile_configs.flat_map { |value| ["--config", value] },
     "build", "-p", "converter-ffi", "--release", "--target-dir", local_target_dir(root),
     "--features", "piper-runtime", "--jobs", "1"]
  end

  def library_path(root)
    File.join(local_target_dir(root), "release", LIBRARY)
  end

  def stamp_path(root)
    "#{library_path(root)}.inputs.json"
  end

  # Path packages: their directory and every target root cargo compiles.
  def path_packages(metadata, root)
    metadata.fetch("packages").select { |package| package["source"].nil? }.to_h do |package|
      directory = File.dirname(package.fetch("manifest_path"))
      roots = package.fetch("targets").map { |target| target.fetch("src_path") }
      [package.fetch("name"), { "directory" => directory.delete_prefix("#{root}/"), "roots" => roots }]
    end
  end

  # Tracked and untracked-but-not-ignored files, so uncommitted edits count.
  def file_digests(root, directories)
    output, error, status = Open3.capture3("git", "-C", root, "ls-files", "-z", "-c", "-o",
                                           "--exclude-standard", "--", *directories)
    raise "git ls-files failed: #{error.strip}" unless status.success?
    output.split("\0").uniq.sort.to_h do |relative|
      path = File.join(root, relative)
      [relative, File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"]
    end
  end

  def inputs(root, packages, environment)
    global = GLOBAL_INPUTS.to_h do |relative|
      path = File.join(root, relative)
      [relative, File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"]
    end
    {
      "version" => STAMP_VERSION,
      "profile" => profile_configs,
      "global" => global.merge(environment),
      "files" => file_digests(root, packages.values.map { |package| package.fetch("directory") }.uniq)
    }
  end

  def read_stamp(root)
    path = stamp_path(root)
    return nil unless File.file?(path) && !File.symlink?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # :reuse when the dylib is exactly what the stamp says and every input
  # matches. Otherwise :touch lists files whose content may differ from what
  # the shared outputs were built from; :all_roots means no usable record.
  # Dependencies between crates are tracked by cargo's own fingerprints.
  def plan(current, stamp, library, outputs_present:)
    unless stamp.is_a?(Hash) && stamp["version"] == STAMP_VERSION
      # Without a record, existing intermediates may come from any checkout.
      return { action: :build, touch: [], all_roots: outputs_present }
    end
    recorded = stamp.fetch("inputs", {})
    library_present = File.file?(library) && !File.symlink?(library)
    if library_present && recorded == current && stamp["library_sha256"] &&
       stamp["library_sha256"] == Digest::SHA256.file(library).hexdigest
      return { action: :reuse, touch: [], all_roots: false }
    end
    previous = recorded.fetch("files", {})
    changed = current.fetch("files").reject { |file, digest| previous[file] && previous[file] == digest }.keys
    { action: :build, touch: changed, all_roots: false }
  end

  # A failed build may leave a touched file's crate uncompiled; record those
  # files as unknown so the next run from any checkout touches them again.
  def failed_attempt_inputs(current, touched)
    current.merge("files" => current.fetch("files").to_h { |file, digest| [file, touched.include?(file) ? nil : digest] })
  end

  def touch(root, relatives, now: Time.now)
    relatives.each do |relative|
      path = File.join(root, relative)
      File.utime(now, now, path) if File.file?(path) && !File.symlink?(path)
    end
  end

  def touch_all_roots(packages, now: Time.now)
    packages.each_value do |package|
      package.fetch("roots").each { |path| File.utime(now, now, path) if File.file?(path) }
    end
  end

  # library_sha256 is nil after a failed build: never reusable as is.
  def write_stamp(root, inputs, library_sha256)
    record = { "version" => STAMP_VERSION, "inputs" => inputs, "library_sha256" => library_sha256 }
    FileUtils.mkdir_p(File.dirname(stamp_path(root)))
    temporary = "#{stamp_path(root)}.tmp-#{Process.pid}"
    File.write(temporary, JSON.pretty_generate(record) + "\n")
    File.rename(temporary, stamp_path(root))
  end

  def macos12_compatible?(library)
    load_commands, status = Open3.capture2("xcrun", "otool", "-l", library)
    raise "otool failed for #{library}" unless status.success?
    minimum = load_commands[/\bminos\s+(\S+)/, 1] || load_commands[/LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\S+)/m, 1]
    minimum && Gem::Version.new(minimum) <= Gem::Version.new("12.0")
  end

  def capture!(root, *command)
    output, error, status = Open3.capture3(*command, chdir: root)
    raise "#{command.join(" ")} failed: #{error.strip}" unless status.success?
    output
  end

  def main(root: File.expand_path("..", __dir__))
    raise "converter-ffi:build:local supports macOS only" unless RUBY_PLATFORM.include?("darwin")
    runtime = IO.popen(["mise", "exec", "--", "ruby", "scripts/prepare_onnxruntime_macos.rb"], NativeJob.child_options, &:read).strip
    raise "Failed to prepare Intel ONNX Runtime" unless $?.success? && runtime.start_with?("/")
    environment = { "ORT_LIB_LOCATION" => runtime, "ORT_PREFER_DYNAMIC_LINK" => "1", "MACOSX_DEPLOYMENT_TARGET" => "12.0" }
    runtime_library = File.join(runtime, "libonnxruntime.dylib")
    fingerprint = {
      "rustc" => capture!(root, "mise", "exec", "--", "rustc", "-vV").strip,
      "onnxruntime" => File.file?(runtime_library) ? Digest::SHA256.file(runtime_library).hexdigest : "missing"
    }
    packages = path_packages(JSON.parse(capture!(root, "mise", "exec", "--", "cargo", "metadata", "--format-version", "1", "--offline")), root)
    current = inputs(root, packages, environment.merge(fingerprint))
    library = library_path(root)
    decision = plan(current, read_stamp(root), library,
                    outputs_present: File.directory?(File.join(local_target_dir(root), "release")))
    if decision[:action] == :reuse
      puts "converter-ffi local-dev: Rust inputs unchanged; reusing #{library}"
      return 0
    end
    if decision[:all_roots]
      puts "converter-ffi local-dev: no input record for the existing outputs; rebuilding every path package"
      touch_all_roots(packages)
    elsif !decision[:touch].empty?
      puts "converter-ffi local-dev: #{decision[:touch].size} file(s) differ from the last recorded build; marking them for cargo"
      touch(root, decision[:touch])
    end
    ENV.update(environment)
    ENV.delete("SDKROOT")
    # Same eSpeak data step as converter-ffi:build; the app bundles target/espeak-data.
    espeak = ["cargo", "build", "-p", "espeak-rs-sys", "--features", "compile-espeak-intonations",
              "--target-dir", "target/espeak-data", "--jobs", "1"]
    [espeak, cargo_command(root)].each do |command|
      next if system("mise", "exec", "--", *command, chdir: root)
      code = $?.exitstatus || 1
      unknown = decision[:all_roots] ? current.fetch("files").keys : decision[:touch]
      write_stamp(root, failed_attempt_inputs(current, unknown), nil)
      return code
    end
    raise "cargo reported success but #{library} is missing" unless File.file?(library)
    raise "converter-ffi local-dev exceeds the macOS 12 deployment target" unless macos12_compatible?(library)
    write_stamp(root, current, Digest::SHA256.file(library).hexdigest)
    puts "output: #{library}"
    0
  rescue StandardError => error
    warn "converter-ffi local-dev: #{error.message}"
    1
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative "native_job"
  root = File.expand_path("..", __dir__)
  NativeJob.build_entrypoint(__FILE__, ARGV, build_dir: [File.join(root, "target"), File.join(root, "target/espeak-data")])
  exit ConverterFfiLocalBuild.main(root: root)
end
