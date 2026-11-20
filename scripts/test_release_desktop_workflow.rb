# frozen_string_literal: true

# The v0.9.0 Release Desktop run (44759761233) failed in three jobs whose setup
# had drifted from the CI jobs that pass on master. These checks keep each release
# job on the same native prerequisites as its validated CI counterpart.
require "minitest/autorun"
require "yaml"

class ReleaseDesktopWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def workflow(name) = YAML.load_file(File.join(ROOT, ".github/workflows/#{name}"))

  def setup
    @jobs = workflow("release-desktop.yml").fetch("jobs")
  end

  def index(steps, &block) = steps.index(&block) || flunk("missing step")

  def runs(steps) = steps.map { |step| step.fetch("run", "") }

  # Failure 1: "libconverter_ffi.dylib couldn't be opened" - Xcode embeds a library
  # nothing had built.
  def test_apple_release_builds_the_embedded_rust_library_before_xcode
    steps = @jobs.fetch("swiftui-apple").fetch("steps")
    mise = index(steps) { |step| step.fetch("uses", "").start_with?("jdx/mise-action@") }
    install = index(steps) { |step| step["run"] == "mise install" }
    ffi = index(steps) { |step| step["run"] == "mise run converter-ffi:build" }
    app = index(steps) { |step| step["name"] == "Build macOS .app" }
    assert_operator mise, :<, install
    assert_operator install, :<, ffi
    assert_operator ffi, :<, app
    refute steps.any? { |step| step.fetch("uses", "").start_with?("dtolnay/rust-toolchain@") },
           "Rust comes from the project mise toolchain, like the CodeQL Apple build"
  end

  # Failure 2: "sdkmanager: command not found" - the runner image no longer puts an
  # Android SDK on PATH; the project installs it through mise.
  def test_android_release_uses_the_mise_android_sdk
    job = @jobs.fetch("android")
    steps = job.fetch("steps")
    refute runs(steps).any? { |run| run.match?(/^\s*sdkmanager\b/) }, "no runner sdkmanager"
    assert_includes job.fetch("env").fetch("MISE_ENABLE_TOOLS").split(","), "android-sdk"
    licenses = index(steps) { |step| step.fetch("run", "").include?("mise exec -- sdkmanager --licenses") }
    deps = index(steps) { |step| step.fetch("run", "").include?("mise run android:embedded-deps") }
    build = index(steps) { |step| step["name"] == "Build APK (release)" }
    assert_operator licenses, :<, deps
    assert_operator deps, :<, build
  end

  # Failure 3: "failed to run custom build command for ort-sys" - only the CI
  # Windows job provisioned the pinned ONNX Runtime.
  def test_windows_release_provisions_the_same_onnx_runtime_as_ci
    job = @jobs.fetch("flutter-desktop")
    windows = job.fetch("strategy").fetch("matrix").fetch("include").find { |entry| entry["target"] == "windows" }
    assert_equal "windows-2025", windows.fetch("os"), "same runner image as the CI Windows package"
    steps = job.fetch("steps")
    provision = index(steps) { |step| step.fetch("run", "").include?("scripts/provision_onnxruntime_windows.ps1") }
    assert_equal "runner.os == 'Windows'", steps[provision].fetch("if")
    assert_operator provision, :<, index(steps) { |step| step["name"] == "Build" }
    env = job.fetch("env")
    assert_equal "1", env.fetch("ORT_SKIP_DOWNLOAD")
    assert_equal "1", env.fetch("ORT_PREFER_DYNAMIC_LINK")

    ci = workflow("flutter-rust-faber.yml").fetch("jobs").fetch("windows-package-faber").fetch("steps")
    assert ci.any? { |step| step.fetch("run", "").include?("scripts/provision_onnxruntime_windows.ps1") },
           "the CI Windows package uses the same provisioning script"
    refute ci.any? { |step| step.fetch("run", "").include?("microsoft.ml.onnxruntime/1.24.4") },
           "the pinned ONNX Runtime is defined once, in the script"
  end
end
