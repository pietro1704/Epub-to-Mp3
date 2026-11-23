# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

# Cancelled CodeQL runs upload failed SARIF and poison configuration status.
class CodeqlWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/codeql.yml", __dir__)

  def test_codeql_runs_are_not_cancelled_by_newer_pushes
    workflow = File.read(WORKFLOW)

    assert_includes workflow, "group: codeql-${{ github.workflow }}-${{ github.ref }}"
    assert_includes workflow, "cancel-in-progress: false"
  end

  def test_apple_cache_does_not_restore_across_sonic_source_changes
    jobs = YAML.load_file(WORKFLOW).fetch("jobs")
    cache = jobs.values.flat_map { |job| job.fetch("steps", []) }.find do |step|
      step["name"] == "Reuse compatible Rust dependencies across Apple jobs"
    end
    refute_nil cache
    settings = cache.fetch("with")
    ([settings.fetch("key")] + settings.fetch("restore-keys").lines).each do |key|
      assert_includes key, "native/vendor/espeak-rs-sys/espeak-ng/cmake/**"
      assert_includes key, "native/vendor/espeak-rs-sys/espeak-ng/src/sonic/**"
    end
  end
end

class CodeqlSwiftOrderTest < Minitest::Test
  def test_rust_and_project_generation_run_before_the_tracer_and_without_a_one_job_pin
    steps = YAML.load_file(CodeqlWorkflowTest::WORKFLOW).fetch("jobs").fetch("swift").fetch("steps")
    names = steps.map { |step| step["name"] }
    rust = steps.find { |step| step["name"] == "Build actual embedded Rust library" }
    build = steps.find { |step| step["name"] == "Build Swift target" }
    refute rust.fetch("env", {}).key?("CARGO_BUILD_JOBS")
    assert_equal "3", build.fetch("env").fetch("CODEQL_SWIFT_BUILD_JOBS")
    init = names.index("Initialize CodeQL")
    assert_operator names.index("Build actual embedded Rust library"), :<, init
    assert_operator names.index("Generate Xcode project after native prerequisites exist"), :<, init
    assert_equal init + 1, names.index("Build Swift target")
  end
end

class CodeqlAndroidBuildTest < Minitest::Test
  THROTTLED = "Could not GET 'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugins-bom/2.2.20/kotlin-gradle-plugins-bom-2.2.20.pom'. Received status code 429 from server: Too Many Requests"
  FIXTURE_BUILD = <<~'RUBY'
    outcomes_file = ARGV.fetch(0)
    outcomes = JSON.parse(File.read(outcomes_file))
    line, code = outcomes.shift || abort("Unexpected build attempt")
    File.write(outcomes_file, JSON.generate(outcomes))
    warn line
    Process.kill(code, Process.pid) if code.is_a?(String)
    exit code
  RUBY

  def run_build(*outcomes)
    Dir.mktmpdir("codeql-android-build-") do |directory|
      outcomes_file = File.join(directory, "outcomes.json")
      File.write(outcomes_file, JSON.generate(outcomes))
      run = 'exit CodeqlAndroidBuild.run(ARGV, sleeper: ->(delay) { warn "test sleep=#{delay}" })'
      output, status = Open3.capture2e(
        RbConfig.ruby, "-r", File.expand_path("codeql_android_build", __dir__), "-e", run, "--",
        RbConfig.ruby, "-rjson", "-e", FIXTURE_BUILD, "--", outcomes_file
      )
      [output, status.exitstatus, JSON.parse(File.read(outcomes_file)).length]
    end
  end

  def test_retries_observed_maven_central_rate_limit_and_preserves_output
    output, status, remaining = run_build([THROTTLED, 1], ["Android APK built", 0])
    assert_equal 0, status
    assert_equal 0, remaining
    assert_includes output, THROTTLED
    assert_includes output, "test sleep=30"
    assert_includes output, "Android APK built"
  end

  def test_persistent_throttling_reaches_a_bound_and_returns_last_status
    output, status, remaining = run_build(
      [THROTTLED, 1], [THROTTLED, 7], [THROTTLED, 9], ["Unexpected attempt", 0]
    )
    assert_equal 9, status
    assert_equal 1, remaining
    assert_equal %w[30 90], output.scan(/test sleep=(\d+)/).flatten
  end

  def test_other_failures_and_success_are_not_retried
    [
      ["Kotlin compilation failed", 7],
      ["curl: (22) The requested URL returned error: 429", 1],
      [THROTTLED.sub("repo.maven.apache.org", "example.org"), 1],
      [THROTTLED.sub("429", "404"), 1],
      [THROTTLED, 0]
    ].each do |outcome|
      output, status, remaining = run_build(outcome, ["Unexpected attempt", 0])
      assert_equal outcome.last, status
      assert_equal 1, remaining
      refute_includes output, "test sleep="
    end
  end

  def test_interrupted_build_does_not_retry_an_earlier_429
    output, status, remaining = run_build([THROTTLED, "TERM"], ["Unexpected attempt", 0])
    assert_equal 143, status
    assert_equal 1, remaining
    refute_includes output, "test sleep="
  end

  def test_java_kotlin_job_restores_downloads_and_runs_a_manual_build_before_analysis
    codeql = YAML.load_file(CodeqlWorkflowTest::WORKFLOW).fetch("jobs").fetch("java-kotlin").fetch("steps")
    ci = YAML.load_file(File.expand_path("../.github/workflows/ci.yml", __dir__)).fetch("jobs").fetch("android-jvm").fetch("steps")
    upstream_cache = ci.find { |step| step["name"] == "Restore Gradle dependency downloads" }
    restore = codeql.find { |step| step["name"] == upstream_cache.fetch("name") }
    refute_nil restore
    assert_equal upstream_cache.fetch("uses"), restore.fetch("uses")
    assert_equal upstream_cache.fetch("with").fetch("path"), restore.fetch("with").fetch("path")
    assert_includes restore.fetch("with").fetch("restore-keys"), "-flutter-"
    assert_includes restore.fetch("with").fetch("key"), upstream_cache.fetch("with").fetch("key").split("${{ hashFiles").last
    init = codeql.find { |step| step["name"] == "Initialize CodeQL" }
    build = codeql.find { |step| step["name"] == "Build Android app" }
    analysis = codeql.find { |step| step["name"] == "Analyze" }
    assert_equal "manual", init.fetch("with").fetch("build-mode")
    assert_includes build.fetch("run"), "ruby scripts/codeql_android_build.rb -- mise run flutter:build-apk-debug"
    assert_operator codeql.index(restore), :<, codeql.index(build)
    assert_operator codeql.index(init), :<, codeql.index(build)
    assert_operator codeql.index(build), :<, codeql.index(analysis)
    refute build.key?("continue-on-error")
  end
end
