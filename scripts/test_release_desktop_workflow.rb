# frozen_string_literal: true

# The v0.9.0 Release Desktop run (44759761233) failed in three jobs whose setup
# had drifted from the CI jobs that pass on master. These checks keep each release
# job on the same native prerequisites as its validated CI counterpart.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseDesktopWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def workflow(name)
    YAML.load_file(File.join(ROOT, ".github/workflows/#{name}"))
  end

  def setup
    @jobs = workflow("release-desktop.yml").fetch("jobs")
  end

  def index(steps, &block)
    steps.index(&block) || flunk("missing step")
  end

  def runs(steps)
    steps.map { |step| step.fetch("run", "") }
  end

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

  # The v0.9.0 re-run failed at "Install mise": the project's mise environment runs
  # scripts/xcode_build_paths.rb, which needs the hosted Xcode 16.4 that macos-latest
  # no longer has. The release uses the same macOS image as the CodeQL Apple build.
  def test_apple_release_runs_on_the_validated_macos_image
    codeql = workflow("codeql.yml").fetch("jobs").values.map { |job| job["runs-on"] }.grep(/\Amacos-/).uniq
    assert_equal 1, codeql.size, "one CodeQL macOS image"
    assert_equal codeql.first, @jobs.fetch("swiftui-apple").fetch("runs-on")
  end

  def test_macos_build_targets_the_embedded_library_architecture
    %w[x86_64 arm64].each do |architecture|
      output, error, status = run_macos_build(architecture)
      assert status.success?, error
      assert_includes output.lines.map(&:chomp), "ARCHS=#{architecture}"
    end
  end

  def test_macos_build_rejects_a_library_with_multiple_architectures
    output, error, status = run_macos_build("x86_64 arm64")
    refute status.success?
    assert_empty output, "xcodebuild must not run with an ambiguous architecture"
    assert_includes error, "Expected one macOS converter-ffi architecture"
  end

  def run_macos_build(architecture)
    steps = @jobs.fetch("swiftui-apple").fetch("steps")
    command = steps.find { |step| step["name"] == "Build macOS .app" }.fetch("run")
    Dir.mktmpdir("release-macos-build") do |directory|
      lipo = <<~'SH'
        #!/bin/bash
        [[ "$#" == 2 && "$1" == -archs && "$2" == ../../target/release/libconverter_ffi.dylib ]] || exit 90
        printf '%s\n' "$FIXTURE_ARCHITECTURE"
      SH
      File.write(File.join(directory, "lipo"), lipo)
      File.write(File.join(directory, "xcodebuild"), "#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
      %w[lipo xcodebuild].each { |tool| File.chmod(0o700, File.join(directory, tool)) }
      Open3.capture3(
        { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "FIXTURE_ARCHITECTURE" => architecture },
        "bash", "-eo", "pipefail", "-c", command
      )
    end
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
    # The helper comes from master, not from the tag being built: v0.9.0 predates it.
    assert_match %r{\A\./release-helpers/scripts/provision_onnxruntime_windows\.ps1 }, steps[provision].fetch("run")
    helpers = index(steps) { |step| step.dig("with", "path") == "release-helpers" }
    assert_operator helpers, :<, provision
    assert_equal "master", steps[helpers].fetch("with").fetch("ref")
    assert_equal false, steps[helpers].fetch("with").fetch("persist-credentials")
    assert_equal "runner.os == 'Windows'", steps[helpers].fetch("if")
    assert_operator provision, :<, index(steps) { |step| step["name"] == "Build" }
    assert_includes steps[provision].fetch("run"), '"ORT_SKIP_DOWNLOAD=1" >> $env:GITHUB_ENV'
    assert_includes steps[provision].fetch("run"), '"ORT_PREFER_DYNAMIC_LINK=1" >> $env:GITHUB_ENV'
    refute job.fetch("env").key?("ORT_SKIP_DOWNLOAD"), "Only platform-specific steps provision ONNX Runtime"
    refute job.fetch("env").key?("ORT_PREFER_DYNAMIC_LINK"), "Only platform-specific steps select dynamic linkage"

    ci = workflow("flutter-rust-faber.yml").fetch("jobs").fetch("windows-package-faber").fetch("steps")
    assert ci.any? { |step| step.fetch("run", "").include?("scripts/provision_onnxruntime_windows.ps1") },
           "the CI Windows package uses the same provisioning script"
    refute ci.any? { |step| step.fetch("run", "").include?("microsoft.ml.onnxruntime/1.24.4") },
           "the pinned ONNX Runtime is defined once, in the script"
  end

  def test_linux_release_provisions_and_verifies_onnx_runtime_before_archiving
    steps = @jobs.fetch("flutter-desktop").fetch("steps")
    provision = index(steps) { |step| step["name"] == "Provision the pinned Linux ONNX Runtime" }
    build = index(steps) { |step| step["name"] == "Build" }
    audit = index(steps) { |step| step["name"] == "Verify Linux Rust runtime bundle" }
    archive = index(steps) { |step| step["name"] == "Package Linux build" }
    assert_operator provision, :<, build
    assert_operator build, :<, audit
    assert_operator audit, :<, archive
    assert_equal "runner.os == 'Linux'", steps[provision].fetch("if")
    assert_equal "runner.os == 'Linux'", steps[audit].fetch("if")
    assert_equal "runner.os == 'Linux'", steps[archive].fetch("if")
    provision_script = steps[provision].fetch("run")
    assert_includes provision_script, "bash scripts/fetch_onnxruntime_linux.sh "
    assert_includes provision_script, 'echo "ORT_LIB_LOCATION=$runtime"'
    assert_includes provision_script, 'echo "ORT_SKIP_DOWNLOAD=1"'
    assert_includes provision_script, 'echo "ORT_PREFER_DYNAMIC_LINK=1"'
  end

  def compile_fixture(*arguments)
    text, status = Open3.capture2e("cc", "-shared", "-fPIC", *arguments)
    assert status.success?, text
  end

  def test_linux_release_requires_the_pinned_and_locally_resolved_onnx_runtime
    skip "requires a Linux ELF toolchain" unless RUBY_PLATFORM.include?("linux")

    steps = @jobs.fetch("flutter-desktop").fetch("steps")
    audit = steps.fetch(index(steps) { |step| step["name"] == "Verify Linux Rust runtime bundle" }).fetch("run")
    Dir.mktmpdir("release-linux-linkage") do |directory|
      root = File.realpath(directory)
      bundle_lib = File.join(root, "flutter_app/build/linux/x64/release/bundle/lib")
      runtime = File.join(root, "selected runtime")
      FileUtils.mkdir_p([bundle_lib, runtime])
      soname = "libonnxruntime.so.1"
      runtime_lib = File.join(runtime, soname)
      bundle_runtime = File.join(bundle_lib, soname)
      converter = File.join(bundle_lib, "libconverter_ffi.so")
      runtime_source = File.join(root, "runtime.c")
      converter_source = File.join(root, "converter.c")
      File.write(runtime_source, "int fixture_model(void) { return 42; }")
      File.write(converter_source, "int fixture_model(void); int convert(void) { return fixture_model(); }")
      compile_fixture(runtime_source, "-Wl,-soname,#{soname}", "-o", runtime_lib)
      link_converter = ->(runpath) {
        compile_fixture(converter_source, "-L#{runtime}", "-l:#{soname}", "-Wl,-rpath,#{runpath}", "-o", converter)
      }
      run_audit = -> {
        Open3.capture3({ "ORT_LIB_LOCATION" => runtime, "LD_LIBRARY_PATH" => runtime, "LD_PRELOAD" => nil },
                       "bash", "-c", audit, chdir: root)
      }

      link_converter.call("$ORIGIN")
      _, _, status = run_audit.call
      refute status.success?, "the bundle is missing the ONNX Runtime"

      File.write(bundle_runtime, "different payload")
      _, _, status = run_audit.call
      refute status.success?, "the bundled and pinned ONNX Runtime bytes differ"

      FileUtils.cp(runtime_lib, bundle_runtime)
      output, error, status = run_audit.call
      assert status.success?, "#{output}\n#{error}"
      assert_includes output, "#{soname} => #{bundle_runtime} "

      link_converter.call(runtime)
      output, _, status = run_audit.call
      refute status.success?, "the loader found the source runtime outside the bundle"
      assert_includes output, "#{soname} => #{runtime_lib} "

      File.write(converter_source, <<~C)
        int fixture_model(void);
        int fixture_missing(void);
        int convert(void) { return fixture_model() + fixture_missing(); }
      C
      link_converter.call("$ORIGIN")
      output, error, status = run_audit.call
      refute status.success?, "the converter has an unresolved symbol"
      assert_match(/undefined symbol: fixture_missing/, "#{output}\n#{error}")

      File.write(converter_source, "int convert(void) { return 42; }")
      compile_fixture(converter_source, "-o", converter)
      _, _, status = run_audit.call
      refute status.success?, "the converter lacks a dependency on the bundled SONAME"
    end
  end
end
