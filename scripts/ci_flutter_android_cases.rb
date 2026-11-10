# frozen_string_literal: true

# Loaded by test_ci_runtime_scope.rb with its workflow and process fixtures.
class CiRuntimeScopeTest
  def test_flutter_sdk_is_saved_before_dependency_or_test_failures
    steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
    restore = steps.find { |step| step['name'] == 'Cache Flutter SDK' }
    save = steps.find { |step| step['name'] == 'Retain installed Flutter SDK' }
    install = steps.find { |step| step['name'] == 'Install toolchain' }
    refute_nil save, 'A later test failure must not discard an installed SDK cache'
    assert_pinned_action 'actions/cache/restore', restore.fetch('uses')
    assert_pinned_action 'actions/cache/save', save.fetch('uses')
    assert_equal 'flutter-sdk-cache', restore.fetch('id')
    assert_equal "steps.flutter-sdk-cache.outputs.cache-hit != 'true'", save.fetch('if')
    assert_equal restore.fetch('with'), save.fetch('with')
    assert_equal '~/.local/share/mise/installs/flutter', save.fetch('with').fetch('path')
    assert_includes save.fetch('with').fetch('key'), "hashFiles('mise.toml', 'mise.lock')"
    refute install.key?('continue-on-error')
    assert_operator steps.index(restore), :<, steps.index(install)
    assert_operator steps.index(install), :<, steps.index(save)
    ['Install Flutter dependencies', 'Run Flutter tests', 'Run Flutter analyzer'].each do |name|
      assert_operator steps.index(save), :<, steps.index(steps.find { |step| step['name'] == name })
    end
  end

  def test_flutter_sdk_cache_keeps_scope_checks_installation_and_validation_on_hits_and_misses
    steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
    cache = steps.find { |step| step['name'] == 'Cache Flutter SDK' }
    refute_nil cache
    assert_pinned_action('actions/cache/restore', cache.fetch('uses'))
    assert_equal '~/.local/share/mise/installs/flutter', cache.fetch('with').fetch('path')
    key = cache.fetch('with').fetch('key')
    %w[runner.os runner.arch].each { |identity| assert_includes key, "${{ #{identity} }}" }
    assert_includes key, "hashFiles('mise.toml', 'mise.lock')"
    refute cache.fetch('with').key?('restore-keys')
    names = steps.map { |step| step['name'] }
    assert_operator names.index('Check Flutter toolchain scope'), :<, names.index('Cache Flutter SDK')
    assert_operator names.index('Cache Flutter SDK'), :<, names.index('Install toolchain')
    ['Install toolchain', 'Install Flutter dependencies', 'Run Flutter tests', 'Run Flutter analyzer'].each do |name|
      step = steps.find { |entry| entry['name'] == name }
      if name == 'Run Flutter tests'
        assert_equal "${{ !cancelled() && steps.flutter-dependencies.outcome == 'success' }}", step.fetch('if')
      else
        refute step.key?('if'), "#{name} must run after either a cache hit or miss"
      end
      refute step.key?('continue-on-error'), "#{name} failures must block validation"
    end
    assert_equal 'mise install', steps.find { |step| step['name'] == 'Install toolchain' }.fetch('run')
  end

  def test_android_jvm_selection_covers_platform_and_dependency_changes_without_dart_only_builds
    %w[flutter_app/android/app/src/main/kotlin/Removed.kt flutter_app/android/gradle.properties
       flutter_app/pubspec.yaml flutter_app/pubspec.lock scripts/android_jni_exports.rb
       scripts/fetch_onnxruntime_android.rb].each do |path|
      selected, status, err = scope([path])
      assert status.success?, err
      assert_equal 'true', selected.fetch('android'), path
    end
    %w[flutter_app/lib/features/reader/reader_view.dart flutter_app/test/reader_test.dart
       flutter_app/linux/CMakeLists.txt docs/android.md].each do |path|
      selected, status, err = scope([path])
      assert status.success?, err
      assert_equal 'false', selected.fetch('android'), path
    end
  end

  def test_android_jvm_gate_rejects_missing_failed_cancelled_and_skipped_results
    selected, status, err = scope(['flutter_app/android/app/src/test/kotlin/ExampleTest.kt'])
    assert status.success?, err
    assert gate(selected).success?
    %w[failure cancelled skipped].each { |result| refute gate(selected, 'android-jvm' => result).success? }
    refute gate(selected.reject { |name, _| name == 'android' }).success?
    refute gate(selected.merge('android' => 'unknown')).success?
    assert gate(selected, {}, true).success?
    refute gate(selected, { 'android-jvm' => 'success' }, true).success?
    job = @workflow.fetch('jobs').fetch('android-jvm')
    integrated = "inputs.full_validation == true && github.event_name == 'push' && github.ref == 'refs/heads/master'"
    assert_equal "needs.changes.outputs.android == 'true' && !(#{integrated})", job.fetch('if')
    assert_equal '${{ inputs.full_validation == true && 30 || 12 }}', job.fetch('timeout-minutes')
    assert_equal 'python,ruby,flutter,java', job.fetch('env').fetch('MISE_ENABLE_TOOLS')
    refute job.fetch('steps').any? { |step| step['continue-on-error'] }
  end

  def test_flutter_pipeline_retains_real_failure_and_cancellation_status_with_logs
    steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
    analyzer = steps.find { |step| step['name'] == 'Run Flutter analyzer' }
    tests = steps.find { |step| step['name'] == 'Run Flutter tests' }
    assert_operator steps.index(analyzer), :<, steps.index(tests)
    fake = File.join(@root, 'mise')
    File.write(fake, "#!/bin/sh\necho fixture-diagnostic\n[ \"$FIXTURE_EXIT\" = cancelled ] && kill -TERM $$\nexit \"$FIXTURE_EXIT\"\n")
    File.chmod(0o700, fake)
    [analyzer, tests].each do |step|
      %w[0 23 cancelled].each do |result|
        _, err, status = Open3.capture3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'FIXTURE_EXIT' => result },
          'bash', '-e', '-o', 'pipefail', '-c', step.fetch('run'), chdir: @root)
        assert_equal result == 'cancelled' ? 143 : result.to_i, status.exitstatus, err
        assert_includes File.read(File.join(@root, '.reports/flutter', step == analyzer ? 'analyze.log' : 'tests.log')), 'fixture-diagnostic'
      end
    end
    artifact = steps.find { |step| step['name'] == 'Retain Flutter failure diagnostics' }
    assert_equal 'failure() || cancelled()', artifact.fetch('if')
    assert_pinned_action 'actions/upload-artifact', artifact.fetch('uses')
  end

  def test_android_jvm_evidence_requires_executed_cases_and_rejects_missing_or_bad_reports
    steps = @workflow.fetch('jobs').fetch('android-jvm').fetch('steps')
    evidence = steps.find { |step| step['name'] == 'Require executed Android JVM cases' }.fetch('run')
    fake = File.join(@root, 'mise')
    File.write(fake, "#!/bin/sh\nshift\nshift\nexec \"$@\"\n")
    File.chmod(0o700, fake)
    report_dir = File.join(@root, 'flutter_app/build/app/test-results/testDebugUnitTest')
    FileUtils.mkdir_p(report_dir)
    execute = -> { Open3.capture3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}" }, 'bash', '-e', '-c', evidence, chdir: @root).last }
    refute execute.call.success?, 'Missing results cannot pass'
    report = File.join(report_dir, 'TEST-example.xml')
    [[2, 0, 0, 0], [0, 0, 0, 0], [2, 1, 0, 0], [2, 0, 1, 0], [2, 0, 0, 1]].each do |counts|
      attributes = %w[tests failures errors skipped].zip(counts).map { |name, count| "#{name}=\"#{count}\"" }.join(' ')
      File.write(report, "<testsuite #{attributes}/>")
      assert_equal counts == [2, 0, 0, 0], execute.call.success?, counts.inspect
    end
    File.write(report, '<invalid')
    refute execute.call.success?
    retention = steps.find { |step| step['name'] == 'Retain Android JVM test results' }
    assert_equal 'always()', retention.fetch('if')
  end

  def test_android_wrapper_bootstrap_preserves_pinned_distribution_and_fails_without_sdk_inputs
    steps = @workflow.fetch('jobs').fetch('android-jvm').fetch('steps')
    bootstrap = steps.find { |step| step['name'] == 'Bootstrap the ignored wrapper from the pinned Flutter SDK' }.fetch('run')
    sdk = File.join(@root, 'sdk')
    source = File.join(sdk, 'bin/cache/artifacts/gradle_wrapper')
    destination = File.join(@root, 'flutter_app/android')
    [source, destination].each { |path| FileUtils.mkdir_p(File.join(path, 'gradle/wrapper')) }
    File.write(File.join(source, 'gradlew'), '#!/bin/sh')
    jar = File.join(source, 'gradle/wrapper/gradle-wrapper.jar')
    File.binwrite(jar, "sdk-wrapper\x00fixture")
    properties = File.join(destination, 'gradle/wrapper/gradle-wrapper.properties')
    pinned = File.binread(File.expand_path('../flutter_app/android/gradle/wrapper/gradle-wrapper.properties', __dir__))
    File.binwrite(properties, pinned)
    fake = File.join(@root, 'mise')
    File.write(fake, "#!/bin/sh\nprintf '%s\\n' \"$FIXTURE_SDK\"\n")
    File.chmod(0o700, fake)
    execute = -> { Open3.capture3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'FIXTURE_SDK' => sdk }, 'bash', '-e', '-c', bootstrap, chdir: @root).last }
    2.times do
      assert execute.call.success?
      assert_equal pinned, File.binread(properties)
      assert_equal File.binread(jar), File.binread(File.join(destination, 'gradle/wrapper/gradle-wrapper.jar'))
      assert File.executable?(File.join(destination, 'gradlew'))
    end
    File.unlink(jar)
    refute execute.call.success?
    assert_equal pinned, File.binread(properties)
  end
end
