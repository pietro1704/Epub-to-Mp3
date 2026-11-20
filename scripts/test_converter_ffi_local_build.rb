# frozen_string_literal: true

# Host-only coverage for the local Debug Mac Rust loop. No compiler, Xcode or
# app is started: cargo/codesign are fakes and inputs are temporary fixtures.
require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "converter_ffi_local_build"
require_relative "mise_task_bodies"

class ConverterFfiLocalBuildTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  Build = ConverterFfiLocalBuild

  def setup
    @root = File.realpath(Dir.mktmpdir("local ffi fixture "))
    git("init", "-q")
    write("Cargo.toml", "[workspace]\n")
    write("Cargo.lock", "# lock\n")
    write("crates/core/src/lib.rs", "pub fn core() {}\n")
    write("crates/ffi/src/lib.rs", "pub fn ffi() {}\n")
    write("crates/ffi/build.rs", "fn main() {}\n")
    git("add", ".")
    @packages = {
      "core" => { "directory" => "crates/core", "roots" => [File.join(@root, "crates/core/src/lib.rs")] },
      "ffi" => { "directory" => "crates/ffi", "roots" => [File.join(@root, "crates/ffi/src/lib.rs"), File.join(@root, "crates/ffi/build.rs")] }
    }
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def git(*arguments)
    _, error, status = Open3.capture3("git", "-C", @root, *arguments)
    assert status.success?, error
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def inputs
    Build.inputs(@root, @packages, { "rustc" => "fixture" })
  end

def build_library(current)
  write("target/local-dev/release/libconverter_ffi.dylib", "dylib bytes")
  Build.write_stamp(@root, current, Digest::SHA256.file(Build.library_path(@root)).hexdigest)
end

def plan
  Build.plan(inputs, Build.read_stamp(@root), Build.library_path(@root),
             outputs_present: File.directory?(File.join(@root, "target/local-dev/release")))
end

def building(touch: [], all_roots: false)
  { action: :build, touch: touch, all_roots: all_roots }
end

def test_local_overrides_stay_out_of_the_manifest_and_the_release_target_directory
  manifest = File.read(File.join(ROOT, "Cargo.toml"))
  refute_includes manifest, "local-dev"
  assert_match(/\[profile\.release\]\ncodegen-units = 1\nlto = "thin"\nstrip = true\n/, manifest)
  command = Build.cargo_command("/checkout")
  assert_equal ["--target-dir", "/checkout/target/local-dev"], command[command.index("--target-dir"), 2]
  assert_includes command, "--release"
  assert_equal %w[--jobs 1], command.last(2)
  overrides = command.each_cons(2).select { |flag, _| flag == "--config" }.map(&:last)
  assert_equal Build.profile_configs, overrides
  assert(overrides.all? { |value| value.start_with?("profile.release.") })
  assert_includes overrides, "profile.release.lto=false"
  assert_equal "/checkout/target/local-dev/release/libconverter_ffi.dylib", Build.library_path("/checkout")
end

def test_cold_target_builds_without_touching_sources
  assert_equal building, plan
end

def test_identical_inputs_reuse_the_library_without_cargo
  build_library(inputs)
  assert_equal :reuse, plan[:action]
end

def test_content_edit_with_an_older_mtime_marks_only_that_file
  build_library(inputs)
  source = File.join(@root, "crates/core/src/lib.rs")
  old = File.mtime(source) - 3600
  write("crates/core/src/lib.rs", "pub fn core() { /* edited in another worktree */ }\n")
  File.utime(old, old, source)
  assert_equal building(touch: ["crates/core/src/lib.rs"]), plan
end

def test_file_included_from_another_package_is_marked_itself
  # converter-core compiles a piper-rs file through #[path]; touching that
  # file (not a package root) is what cargo dep-info tracks.
  build_library(inputs)
  write("crates/ffi/src/shared_config.rs", "pub const SHARED: u8 = 1;\n")
  assert_equal building(touch: ["crates/ffi/src/shared_config.rs"]), plan
end

def test_untracked_source_counts_and_ignored_output_does_not
  build_library(inputs)
  write(".gitignore", "crates/ffi/generated/\n")
  git("add", ".gitignore")
  write("crates/ffi/generated/out.rs", "ignored")
  assert_equal :reuse, plan[:action]
  write("crates/ffi/src/new_module.rs", "pub fn added() {}\n")
  assert_equal building(touch: ["crates/ffi/src/new_module.rs"]), plan
end

def test_changed_library_bytes_or_global_inputs_rebuild_without_touching
  build_library(inputs)
  write("target/local-dev/release/libconverter_ffi.dylib", "replaced by something else")
  assert_equal building, plan
  build_library(inputs)
  write("Cargo.lock", "# updated lock\n")
  assert_equal building, plan
end

def test_failed_attempt_is_never_reused_and_keeps_its_touched_files_unknown
  build_library(inputs)
  write("crates/core/src/lib.rs", "pub fn core() { compile_error!() }\n")
  attempt = plan
  assert_equal ["crates/core/src/lib.rs"], attempt[:touch]
  Build.write_stamp(@root, Build.failed_attempt_inputs(inputs, attempt[:touch]), nil)
  # Another checkout with the same content must still mark the file.
  assert_equal building(touch: ["crates/core/src/lib.rs"]), plan
  File.delete(Build.library_path(@root))
  assert_equal building(touch: ["crates/core/src/lib.rs"]), plan
end

def test_missing_or_foreign_stamp_with_outputs_rebuilds_every_package
  write("target/local-dev/release/libconverter_ffi.dylib", "dylib bytes")
  assert_equal building(all_roots: true), plan
  write("target/local-dev/release/libconverter_ffi.dylib.inputs.json", "not json")
  assert_equal building(all_roots: true), plan
  File.delete(Build.library_path(@root))
  assert_equal building(all_roots: true), plan, "intermediates without a record come from an unknown checkout"
end

def test_touch_updates_only_the_listed_files_and_all_roots_covers_build_scripts
  past = Time.at(1_000_000_000)
  files = %w[crates/core/src/lib.rs crates/ffi/src/lib.rs crates/ffi/build.rs].map { |relative| File.join(@root, relative) }
  files.each { |path| File.utime(past, past, path) }
  now = Time.at(2_000_000_000)
  Build.touch(@root, ["crates/ffi/src/lib.rs", "crates/removed.rs"], now: now)
  assert_equal [past, now, past], files.map { |path| File.mtime(path) }
  Build.touch_all_roots(@packages, now: now)
  files.each { |path| assert_equal now, File.mtime(path) }
end

  def test_path_packages_come_from_cargo_metadata_without_registry_crates
    metadata = { "packages" => [
      { "name" => "core", "source" => nil, "manifest_path" => File.join(@root, "crates/core/Cargo.toml"),
        "targets" => [{ "src_path" => File.join(@root, "crates/core/src/lib.rs") }] },
      { "name" => "serde", "source" => "registry+https://github.com/rust-lang/crates.io-index",
        "manifest_path" => "/registry/serde/Cargo.toml", "targets" => [{ "src_path" => "/registry/serde/src/lib.rs" }] }
    ] }
    packages = Build.path_packages(metadata, @root)
    assert_equal ["core"], packages.keys
    assert_equal "crates/core", packages["core"]["directory"]
  end

  # Cargo's cache cleanup can delete the downloaded .crate archives while the
  # extracted sources stay, and `cargo metadata --offline` then fails
  # ("--offline was specified"): mac:test:local stopped on adler2 on 2026-11-20.
  def test_offline_metadata_fetches_the_locked_crates_once_when_the_cache_lost_them
    calls = []
    metadata = '{"packages":[]}'
    run = lambda do |root, *command|
      calls << command
      if command.include?("metadata") && calls.count { |call| call.include?("metadata") } == 1
        raise "mise exec -- cargo metadata failed: error: failed to download `adler2 v2.0.1`\n\n" \
              "Caused by:\n  attempting to make an HTTP request, but --offline was specified"
      end
      command.include?("metadata") ? metadata : ""
    end
    assert_equal metadata, Build.cargo_metadata(@root, run: run)
    offline = %w[mise exec -- cargo metadata --format-version 1 --offline]
    assert_equal [offline, %w[mise exec -- cargo fetch --locked], offline], calls
  end

  def test_other_metadata_failures_are_not_retried
    calls = []
    run = lambda do |_root, *command|
      calls << command
      raise "mise exec -- cargo metadata failed: error: failed to parse manifest"
    end
    error = assert_raises(RuntimeError) { Build.cargo_metadata(@root, run: run) }
    assert_match(/failed to parse manifest/, error.message)
    assert_equal 1, calls.size, "no fetch for an unrelated failure"
  end

  def test_local_task_is_guarded_and_release_tasks_never_use_the_local_profile
    bodies = MiseTaskBodies.load(ROOT, %w[converter-ffi:build:local mac:test:local converter-ffi:build mac:build
                                          mac:validate converter-ffi:ios-device])
    assert_includes bodies.fetch("converter-ffi:build:local"), "scripts/converter_ffi_local_build.rb"
    assert_includes File.read(File.join(ROOT, "scripts/converter_ffi_local_build.rb")), "NativeJob.build_entrypoint"
    local_test = bodies.fetch("mac:test:local")
    assert_match(/native_job\.rb" --build-dir "\$APPLE_DERIVED_DATA_PATH" build --/, local_test)
    assert_match(/-jobs 1 -parallel-testing-enabled NO/, local_test)
    assert_includes local_test, "-configuration Debug"
    %w[converter-ffi:build mac:build mac:validate converter-ffi:ios-device].each do |name|
      refute_match(/local-dev|EPUB2MP3_LOCAL_FFI_DYLIB|converter-ffi:build:local/, bodies.fetch(name), name)
    end
    %w[package_converter_ffi_macos.rb package_converter_ffi_ios.rb mac_validate.rb download_converter_ffi_macos.rb
       codeql_swift_build.sh bundle_converter_ffi_ios.sh bundle_onnxruntime_apple.sh].each do |script|
      refute_match(/local-dev|EPUB2MP3_LOCAL_FFI_DYLIB/, File.read(File.join(ROOT, "scripts", script)), script)
    end
    Dir.glob(File.join(ROOT, ".github/workflows/*.yml")).each do |workflow|
      refute_match(/local-dev|EPUB2MP3_LOCAL_FFI_DYLIB|mac:test:local|converter-ffi:build:local/, File.read(workflow), workflow)
    end
    project = File.read(File.join(ROOT, "ios/EpubToMp3/project.yml"))
    assert_includes project, "- path: ../../target/release/libconverter_ffi.dylib"
    refute_includes project, "target/local-dev"
  end

  def test_local_task_rejects_compiler_flags_before_any_build
    body = MiseTaskBodies.load(ROOT, ["mac:test:local"]).fetch("mac:test:local")
    _, error, status = Open3.capture3({ "MISE_PROJECT_ROOT" => @root }, "/bin/bash", "-c", body, "mac:test:local", "-jobs", "4")
    assert_equal 2, status.exitstatus
    assert_includes error, "accepts -only-testing:ID"
  end
end
