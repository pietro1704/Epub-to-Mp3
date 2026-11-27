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

  def test_build_jobs_start_from_trusted_history_and_isolate_release_caches
    %w[docker android macos-native flutter-desktop].each do |name|
      job = @jobs.fetch(name)
      dependencies = name == "docker" ? "gate" : %w[gate native-notices]
      assert_equal dependencies, job.fetch("needs")
      checkout, select_source, = job.fetch("steps")
      assert_match(/\Aactions\/checkout@[0-9a-f]{40}\z/, checkout.fetch("uses"))
      assert_equal({
        "ref" => "refs/heads/master", "fetch-depth" => 0, "persist-credentials" => false
      }, checkout.fetch("with"))
      assert_equal "bash scripts/checkout_validated_release_source.sh", select_source.fetch("run")
      assert_equal "bash", select_source.fetch("shell")
      assert_equal({ "VALIDATED_SHA" => "${{ needs.gate.outputs.sha }}" }, select_source.fetch("env"))

      job.fetch("steps").each do |step|
        action = step.fetch("uses", "").split("@").first
        refute_match(/\A(?:actions\/cache|\.\/\.github\/actions\/rust-build-cache)/, action.to_s)
        case action
        when "jdx/mise-action"
          assert_equal false, step.dig("with", "cache")
        when "docker/setup-buildx-action"
          assert_equal false, step.dig("with", "cache-binary")
        when "docker/build-push-action"
          refute (step.fetch("with").keys & %w[cache-from cache-to]).any?
        end
      end
    end
  end

  def test_validated_notices_reach_native_packages_before_signing_or_archiving
    job = @jobs.fetch("native-notices")
    assert_equal "gate", job.fetch("needs")
    assert_equal "./.github/workflows/release-native-notices.yml", job.fetch("uses")
    assert_equal "${{ needs.gate.outputs.sha }}", job.dig("with", "source_sha")
    producer = workflow("release-native-notices.yml").dig("jobs", "stage", "steps")
    assert_equal 0, producer.first.dig("with", "fetch-depth")
    assert_equal "refs/heads/master", producer.first.dig("with", "ref")
    assert_equal "native-third-party-notices", producer.last.dig("with", "name")
    assert_equal "error", producer.last.dig("with", "if-no-files-found")

    destinations = {
      "android" => ["flutter_app/android/app/src/main/assets", "Build APK (release)"],
      "macos-native" => ["ios/EpubToMp3/build/Build/Products/Release/EpubToMp3.app/Contents/Resources",
        "Seal macOS .app"],
      "flutter-desktop" => ["${{ matrix.package_root }}", "Package Linux build"]
    }
    destinations.each do |name, (destination, package_step)|
      steps = @jobs.fetch(name).fetch("steps")
      download = index(steps) { |step| step.dig("with", "name") == "native-third-party-notices" }
      packaging = index(steps) { |step| step["name"] == package_step }
      assert_equal "#{destination}/ThirdPartyNotices", steps[download].dig("with", "path")
      assert_operator download, :<, packaging, name
    end
    desktop = @jobs.fetch("flutter-desktop")
    assert_equal %w[flutter_app/build/linux/x64/release/bundle flutter_app/build/windows/x64/runner/Release],
      desktop.dig("strategy", "matrix", "include").map { |entry| entry.fetch("package_root") }
    steps = desktop.fetch("steps")
    assert_operator index(steps) { |step| step.dig("with", "name") == "native-third-party-notices" }, :<,
      index(steps) { |step| step["name"] == "Package Windows build" }
  end

  def test_android_publication_requires_the_staged_source_notice_in_the_signed_apk
    steps = @jobs.fetch("android").fetch("steps")
    audit = index(steps) { |step| step["name"] == "Verify signed APK native notices" }
    assert_operator index(steps) { |step| step["name"] == "Sign and verify the official Android APK" }, :<, audit
    assert_operator audit, :<, index(steps) { |step| step.dig("with", "name") == "release-android" }
    command = steps[audit].fetch("run")
    Dir.mktmpdir("release-android-notice") do |directory|
      notice = "assets/ThirdPartyNotices/SOURCE.md"
      packaged = File.join(directory, notice)
      staged = File.join(directory, "flutter_app/android/app/src/main", notice)
      apk = File.join(directory, "EpubToMp3_android.apk")
      [packaged, staged, apk].each { |file| FileUtils.mkdir_p(File.dirname(file)) }
      File.write(packaged, "validated source\n")
      _, error, status = Open3.capture3("zip", "-q", apk, notice, chdir: directory)
      assert status.success?, error

      File.write(staged, "different source\n")
      _, _, status = Open3.capture3("bash", "-eo", "pipefail", "-c", command, chdir: directory)
      refute status.success?
      FileUtils.cp(packaged, staged)
      _, error, status = Open3.capture3("bash", "-eo", "pipefail", "-c", command, chdir: directory)
      assert status.success?, error
    end
  end

  def test_official_android_signing_is_required_before_build_and_publication
    steps = @jobs.fetch("android").fetch("steps")
    reference = index(steps) { |step| step["name"] == "Require official Android signing inputs" }
    build = index(steps) { |step| step["name"] == "Build APK (release)" }
    sign = index(steps) { |step| step["name"] == "Sign and verify the official Android APK" }
    assert_operator reference, :<, build
    assert_operator build, :<, sign
    assert_equal "1", steps[build].dig("env", "EPUBTOPMP3_ANDROID_OFFICIAL_RELEASE")
    refute_includes steps[build].fetch("env").to_s, "secrets."
    assert_equal 4, steps[sign].fetch("env").size
    assert_includes steps[sign].fetch("run"), "--ks-pass env:APK_STORE_PASSWORD --key-pass env:APK_KEY_PASSWORD"
    assert_includes steps[sign].fetch("run"), "mise exec -- ruby scripts/verify_android_release_signature.rb"

    publisher = @jobs.fetch("publish")
    assert_includes publisher.fetch("needs"), "android"
    publish_steps = publisher.fetch("steps")
    download = index(publish_steps) { |step| step.fetch("uses", "").start_with?("actions/download-artifact@") }
    verify = index(publish_steps) { |step| step.fetch("run", "").include?("verify_android_release_signature.rb release-assets/EpubToMp3_android.apk") }
    publish = index(publish_steps) { |step| step.fetch("run", "").include?("gh release upload") }
    assert_operator download, :<, verify
    assert_operator verify, :<, publish
    assert_includes publish_steps[publish].fetch("run"), "release-assets/EpubToMp3_android.apk"
    refute_includes publish_steps[publish].fetch("run"), "release-assets/*.apk"
  end

  def test_release_source_accepts_exact_historical_commit_and_rejects_off_history_objects
    script = File.join(ROOT, "scripts/checkout_validated_release_source.sh")
    Dir.mktmpdir("release-source-history-") do |directory|
      git = ->(*args) do
        output, error, status = Open3.capture3("git", *args, chdir: directory)
        assert status.success?, "git #{args.join(' ')}: #{error}"
        output.strip
      end
      git.call("init", "-q", "-b", "master")
      git.call("config", "user.name", "Release fixture")
      git.call("config", "user.email", "release-fixture@example.invalid")
      git.call("commit", "--allow-empty", "-qm", "release")
      release = git.call("rev-parse", "HEAD")
      git.call("tag", "-am", "release", "v1.2.3")
      tag_object = git.call("rev-parse", "v1.2.3")
      git.call("switch", "-qc", "outside-master")
      git.call("commit", "--allow-empty", "-qm", "outside")
      outside = git.call("rev-parse", "HEAD")
      git.call("switch", "-q", "master")
      git.call("commit", "--allow-empty", "-qm", "advance master")
      master = git.call("rev-parse", "HEAD")

      [nil, "v1.2.3", "0" * 40, tag_object, outside].each do |invalid|
        _, error, status = Open3.capture3({ "VALIDATED_SHA" => invalid }, "bash", script, chdir: directory)
        refute status.success?, "unexpected acceptance of #{invalid.inspect}"
        assert_includes error, "::error::"
        assert_equal master, git.call("rev-parse", "HEAD")
      end

      _, error, status = Open3.capture3({ "VALIDATED_SHA" => release }, "bash", script, chdir: directory)
      assert status.success?, error
      assert_equal release, git.call("rev-parse", "HEAD")
      assert_equal "", git.call("branch", "--show-current")
      assert_equal master, git.call("rev-parse", "refs/heads/master")
    end
  end

  # Failure 1: "libconverter_ffi.dylib couldn't be opened" - Xcode embeds a library
  # nothing had built.
  def test_apple_release_builds_the_embedded_rust_library_before_xcode
    steps = @jobs.fetch("macos-native").fetch("steps")
    mise = index(steps) { |step| step.fetch("uses", "").start_with?("jdx/mise-action@") }
    install = index(steps) { |step| step["run"] == "mise install rust" }
    # mise has no precompiled Ruby for macos-x64; the build scripts use the runner's Ruby.
    assert_equal "rust", @jobs.fetch("macos-native").dig("env", "MISE_ENABLE_TOOLS")
    ffi = index(steps) { |step| step["run"] == "mise run converter-ffi:build" }
    app = index(steps) { |step| step["name"] == "Build macOS .app" }
    assert_operator mise, :<, install
    assert_operator install, :<, ffi
    assert_operator ffi, :<, app
    refute steps[ffi].fetch("env", {}).key?("CARGO_BUILD_JOBS"),
           "the native guard owns the hosted compiler job limit"
    refute steps.any? { |step| step.fetch("uses", "").start_with?("dtolnay/rust-toolchain@") },
           "Rust comes from the project mise toolchain, like the CodeQL Apple build"
  end

  def test_desktop_apple_job_only_builds_the_published_macos_package
    job = @jobs.fetch("macos-native")
    assert_equal "macOS native", job.fetch("name")
    refute_match(/generic\/platform=iOS|\.xcarchive|\.ipa\b/, runs(job.fetch("steps")).join("\n"))
    package = job.fetch("steps").find { |step| step.dig("with", "name").to_s.start_with?("release-apple") }
    refute_nil package
    assert_equal "ios/EpubToMp3/EpubToMp3-macos-*.zip", package.dig("with", "path")
  end

  def test_macos_release_seals_and_verifies_the_bundle_before_zipping
    steps = @jobs.fetch("macos-native").fetch("steps")
    build = index(steps) { |step| step["name"] == "Build macOS .app" }
    seal = index(steps) { |step| step["name"] == "Seal macOS .app" }
    package = index(steps) { |step| step["name"] == "Package macOS .app into .zip" }
    assert_operator build, :<, seal
    assert_operator seal, :<, package
    skip "requires macOS codesign and ditto" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir("release-macos-signature") do |directory|
      app = File.join(directory, "build/Build/Products/Release/EpubToMp3.app")
      executable = File.join(app, "Contents/MacOS/EpubToMp3")
      nested = File.join(app, "Contents/Helpers/fixture")
      [executable, nested].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp("/usr/bin/true", path)
      end
      File.write(File.join(app, "Contents/Info.plist"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.release-fixture</string>
        <key>CFBundleExecutable</key><string>EpubToMp3</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>1.2.3</string>
        </dict></plist>
      XML
      _, error, status = Open3.capture3("/usr/bin/codesign", "--force", "--sign", "-", nested)
      assert status.success?, error
      signed_nested = File.binread(nested)
      _, _, status = Open3.capture3("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
      refute status.success?, "the fixture must reproduce the unsealed bundle"

      _, error, status = run_macos_release_step(steps[seal], directory)
      assert status.success?, error
      assert_equal signed_nested, File.binread(nested)
      assert File.file?(File.join(app, "Contents/_CodeSignature/CodeResources"))
      entitlements, error, status = Open3.capture3("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app)
      assert status.success?, error
      %w[app-sandbox network.client files.user-selected.read-write files.bookmarks.app-scope].each do |key|
        assert_includes entitlements, "com.apple.security.#{key}"
      end
      _, error, status = run_macos_release_step(steps[package], directory)
      assert status.success?, error
      archive = File.join(directory, "EpubToMp3-macos-v1.2.3-arm64.zip")
      extracted = File.join(directory, "extracted")
      _, error, status = Open3.capture3("/usr/bin/ditto", "-x", "-k", archive, extracted)
      assert status.success?, error
      _, error, status = Open3.capture3("/usr/bin/codesign", "--verify", "--deep", "--strict",
        File.join(extracted, "EpubToMp3.app"))
      assert status.success?, error

      _, error, status = Open3.capture3("/usr/bin/codesign", "--remove-signature", nested)
      assert status.success?, error
      _, error, status = run_macos_release_step(steps[seal], directory)
      refute status.success?, "an invalid nested signature must block packaging"
      assert_includes error, "fixture"
    end
  end

  # v0.13.0 shipped an arm64-only zip that an Intel Mac cannot run.
  def test_macos_release_publishes_intel_and_apple_silicon_packages
    job = @jobs.fetch("macos-native")
    assert_equal %w[macos-15 macos-15-intel], job.dig("strategy", "matrix", "include").map { |entry| entry.fetch("os") }
    assert_equal "${{ matrix.os }}", job.fetch("runs-on")
    package = job.fetch("steps").find { |step| step.dig("with", "path").to_s.end_with?("EpubToMp3-macos-*.zip") }
    assert_equal "release-apple-${{ matrix.arch }}", package.dig("with", "name")
  end

  # The v0.14.0 zip claimed the App Group, so its library suite moved to the group
  # container and the books saved by builds without that entitlement disappeared.
  # macOS embeds neither the widget nor the share extension, so it needs no group.
  def test_macos_release_keeps_the_library_in_the_app_container
    source = File.join(ROOT, "ios/EpubToMp3/EpubToMp3/Resources/EpubToMp3.entitlements")
    granted = File.read(source).gsub(/<!--.*?-->/m, "").scan(%r{<key>([^<]+)</key>}).flatten

    refute_includes granted, "com.apple.security.application-groups"
    assert_includes granted, "com.apple.security.app-sandbox"
  end

  def run_macos_release_step(step, directory)
    entitlements = "Resources/EpubToMp3.entitlements"
    source = File.join(ROOT, "ios/EpubToMp3/EpubToMp3", entitlements)
    target = File.join(directory, "EpubToMp3", entitlements)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
    Open3.capture3({ "RELEASE_TAG" => "v1.2.3", "MACOS_ARCH" => "arm64" }, "/bin/bash", "-eo", "pipefail",
      "-c", step.fetch("run"), chdir: directory)
  end

  def test_signed_ios_release_provisions_the_rust_target_before_archiving_and_exporting
    steps = workflow("ios-testflight.yml").fetch("jobs").fetch("archive-and-upload").fetch("steps")
    provision = index(steps) { |step| step.fetch("run", "").include?("rustup target add aarch64-apple-ios") }
    archive = index(steps) { |step| step["name"] == "Archive signed iOS app" }
    export = index(steps) { |step| step.fetch("run", "").include?("xcodebuild -exportArchive") }
    upload = index(steps) { |step| step.dig("with", "name") == "EpubToMp3-iOS-IPA" }
    assert_includes steps[provision].fetch("run"), "mise install rust ruby"
    assert_operator provision, :<, archive
    assert_operator archive, :<, export
    assert_operator export, :<, upload
  end

  # The v0.9.0 re-run failed at "Install mise": the project's mise environment runs
  # scripts/xcode_build_paths.rb, which needs the hosted Xcode 16.4 that macos-latest
  # no longer has. The release uses the same macOS image as the CodeQL Apple build.
  def test_apple_release_runs_on_the_validated_macos_image
    codeql = workflow("codeql.yml").fetch("jobs").values.map { |job| job["runs-on"] }.grep(/\Amacos-/).uniq
    assert_equal 1, codeql.size, "one CodeQL macOS image"
    images = @jobs.fetch("macos-native").dig("strategy", "matrix", "include").map { |entry| entry.fetch("os") }
    assert_includes images, codeql.first
  end

  def test_macos_build_targets_the_embedded_library_architecture
    %w[x86_64 arm64].each do |architecture|
      output, error, status = run_macos_build(architecture)
      assert status.success?, error
      assert_includes output.lines.map(&:chomp), "ARCHS=#{architecture}"
      assert_includes output.lines.map(&:chomp), "MARKETING_VERSION=1.2.3"
    end
  end

  def test_macos_build_rejects_a_library_with_multiple_architectures
    output, error, status = run_macos_build("x86_64 arm64")
    refute status.success?
    assert_empty output, "xcodebuild must not run with an ambiguous architecture"
    assert_includes error, "Expected one macOS converter-ffi architecture"
  end

  def test_macos_build_uses_numeric_core_of_suffixed_tags
    %w[v1.2.3-rc.1 v1.2.3+build.1].each do |release_tag|
      output, error, status = run_macos_build("arm64", release_tag: release_tag)
      assert status.success?, error
      assert_includes output.lines.map(&:chomp), "MARKETING_VERSION=1.2.3", release_tag
    end
  end

  def run_macos_build(architecture, release_tag: "v1.2.3")
    steps = @jobs.fetch("macos-native").fetch("steps")
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
        { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "FIXTURE_ARCHITECTURE" => architecture,
          "RELEASE_TAG" => release_tag },
        "bash", "-eo", "pipefail", "-c", command
      )
    end
  end

  def test_macos_package_checks_the_app_version_before_creating_the_zip
    output, error, status = run_macos_package("1.2.3")
    assert status.success?, error
    assert_includes output, "EpubToMp3-macos-v1.2.3-arm64.zip"

    output, error, status = run_macos_package("0.3.0")
    refute status.success?
    assert_empty output, "ditto must not run for a mismatched bundle"
    assert_includes error, "Expected macOS app version 1.2.3, got 0.3.0"
  end

  def test_macos_package_keeps_suffixed_tags_in_zip_names
    %w[v1.2.3-rc.1 v1.2.3+build.1].each do |release_tag|
      output, error, status = run_macos_package("1.2.3", release_tag: release_tag)
      assert status.success?, error
      assert_includes output.lines.map(&:chomp), "EpubToMp3-macos-#{release_tag}-arm64.zip"

      output, error, status = run_macos_package(release_tag.delete_prefix("v"), release_tag: release_tag)
      refute status.success?
      assert_empty output, "ditto must not run if the bundle version contains a suffix"
      assert_includes error, "Expected macOS app version 1.2.3"
    end
  end

  def run_macos_package(bundle_version, release_tag: "v1.2.3")
    steps = @jobs.fetch("macos-native").fetch("steps")
    command = steps.find { |step| step["name"] == "Package macOS .app into .zip" }.fetch("run")
    Dir.mktmpdir("release-macos-package") do |directory|
      app = "build/Build/Products/Release/EpubToMp3.app"
      FileUtils.mkdir_p(File.join(directory, app, "Contents"))
      File.write(File.join(directory, "plutil"), <<~'SH')
        #!/bin/bash
        [[ "$*" == "-extract CFBundleShortVersionString raw -o - build/Build/Products/Release/EpubToMp3.app/Contents/Info.plist" ]] || exit 90
        printf '%s\n' "$FIXTURE_BUNDLE_VERSION"
      SH
      File.write(File.join(directory, "ditto"), "#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
      %w[plutil ditto].each { |tool| File.chmod(0o700, File.join(directory, tool)) }
      Open3.capture3(
        { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "RELEASE_TAG" => release_tag, "MACOS_ARCH" => "arm64",
          "FIXTURE_BUNDLE_VERSION" => bundle_version },
        "bash", "-eo", "pipefail", "-c", command, chdir: directory
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

  # Failure 7: the publish job failed with "apksigner executable not found on PATH"
  # (runs 45517638568 and 45813662154); only the android job installed build-tools.
  def test_publish_installs_the_android_build_tools_before_verifying_the_apk
    job = @jobs.fetch("publish")
    steps = job.fetch("steps")
    install = index(steps) { |step| step.fetch("run", "").include?("build-tools;35.0.0") }
    verify = index(steps) { |step| step.fetch("run", "").include?("verify_android_release_signature.rb release-assets/EpubToMp3_android.apk") }
    assert_operator install, :<, verify
    assert_includes steps[install].fetch("run"), 'mise exec -- sdkmanager "build-tools;35.0.0"'
    assert_includes steps[install].fetch("env").fetch("MISE_ENABLE_TOOLS").split(","), "android-sdk"
    assert_includes steps[install].fetch("run"), "mise exec -- sdkmanager --licenses"
    embedded = File.read(File.expand_path("../mise.toml", __dir__))
    assert_includes embedded, "build-tools;35.0.0", "same build-tools version as android:embedded-deps"
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
