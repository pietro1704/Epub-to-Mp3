# frozen_string_literal: true

# Loaded by test_ci_runtime_scope.rb; preserve the existing suite selectors and fixture.
class CiRuntimeScopeTest
  def test_codeql_builds_only_the_two_production_platform_graphs
    codeql = YAML.load_file(File.expand_path('../.github/workflows/codeql.yml', __dir__))
    swift = codeql.fetch('jobs').fetch('swift')
    normal = swift.fetch('strategy').fetch('matrix').fetch('include')
    assert_kind_of Array, normal
    assert_equal %w[iOS macOS], normal.map { |entry| entry.fetch('platform') }.sort
    assert normal.all? { |entry| entry.fetch('coverage') == 'app' && entry.fetch('scheme') == 'EpubToMp3' && entry.fetch('action') == 'build' }
    assert_equal 2, normal.size
    assert_equal ['generic/platform=iOS', 'generic/platform=macOS'], normal.map { |entry| entry.fetch('destination') }.sort
    events = codeql.fetch('on', codeql[true])
    refute events.key?('pull_request')
    assert events.key?('workflow_call')
    refute events.fetch('workflow_dispatch', {}).to_h.key?('inputs')
    steps = swift.fetch('steps')
    refute steps.any? { |step| step['uses'].to_s.include?('upload-sarif') }
    analyze = steps.find { |step| step['uses'].to_s.start_with?('github/codeql-action/analyze@') }
    refute_nil analyze
    assert_pinned_action('github/codeql-action/analyze', analyze.fetch('uses'))
    assert_equal "${{ format('/language:swift/coverage:{0}/platform:{1}', matrix.coverage, matrix.platform) }}", analyze.fetch('with').fetch('category')
    refute analyze.fetch('with').key?('upload')
    embedded = steps.find { |step| step['name'] == 'Build actual embedded Rust library' }.fetch('run')
    assert_includes embedded, 'mise run converter-ffi:build'
    assert_includes embedded, 'mise run converter-ffi:ios-device:verify'
    refute steps.any? { |step| step['run'].to_s.include?('mise run sidecar:build') },
           'Swift extraction requires the embedded FFI, not the legacy server executable'
    project = YAML.load_file(File.expand_path('../ios/EpubToMp3/project.yml', __dir__))
    assert_equal 'all', project.fetch('schemes').fetch('EpubToMp3').fetch('build').fetch('targets').fetch('EpubToMp3')
    assert_equal ['test'], project.fetch('schemes').fetch('EpubToMp3').fetch('build').fetch('targets').fetch('EpubToMp3Tests')
  end

  def test_flutter_sdk_cache_keeps_scope_checks_installation_and_validation_on_hits_and_misses
    steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
    cache = steps.find { |step| step['name'] == 'Cache Flutter SDK' }
    refute_nil cache
    assert_pinned_action('actions/cache', cache.fetch('uses'))
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
      refute step.key?('if'), "#{name} must run after either a cache hit or miss"
      refute step.key?('continue-on-error'), "#{name} failures must block validation"
    end
    assert_equal 'mise install', steps.find { |step| step['name'] == 'Install toolchain' }.fetch('run')
  end

  def test_shared_player_result_requires_real_cases_without_failures_or_skips
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    steps = faber.fetch('jobs').fetch('macos-preferences').fetch('steps')
    run = steps.find { |step| step['name'] == 'Run real macOS preference and installation XCTest' }.fetch('run')
    assert_includes run, '-only-testing:EpubToMp3Tests/AudioPlayerDivergenceTests'
    assert_includes run, '-only-testing:EpubToMp3Tests/FaberNativeInferenceTests'
    assert_includes run, "grep -F 'FABER_NATIVE firstChunkSeconds='"
    script = steps.find { |step| step['name'] == 'Verify actual player seek execution in the shared XCTest result' }.fetch('run')
    evidence = File.join(@root, '.reports/tts-preferences')
    FileUtils.mkdir_p(File.join(evidence, 'macos-prefs.xcresult'))
    fake = File.join(@root, 'xcrun')
    File.write(fake, "#!/bin/sh\nprintf '%s' \"$FIXTURE_XCRESULT_SUMMARY\"\n")
    File.chmod(0o700, fake)
    names = %w[testStopCancelsReaderPageSeekBeforeDurationArrives testReaderPageSeekCannotCrossJobsAtTheSameChapterIndex testPendingProportionalSeekAppliedOnceDurationLands]
    lines = names.map { |name| "Test Case '-[EpubToMp3Tests.AudioPlayerDivergenceTests #{name}]' passed (0.001 seconds)." }
    suite = "Test Suite 'AudioPlayerDivergenceTests' passed at 2026-10-20.\n  Executed 3 tests, with 0 failures (0 unexpected) in 0.003 seconds\n"
    summary = { 'result' => 'Passed', 'totalTestCount' => 3, 'passedTests' => 3, 'failedTests' => 0, 'skippedTests' => 0 }
    execute = lambda do |log, counts|
      File.write(File.join(evidence, 'macos-prefs.log'), log)
      Open3.capture3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'FIXTURE_XCRESULT_SUMMARY' => JSON.generate(counts) }, RbConfig.ruby, '-e', script, chdir: @root).last
    end
    assert execute.call(lines.join("\n") + "\n" + suite, summary).success?
    assert execute.call(lines.join("\n") + "\n" + suite, summary.merge('totalTestCount' => 8, 'skippedTests' => 5)).success?, 'Unrelated explicit opt-in suites may skip without weakening seek acceptance'
    refute execute.call(suite, summary).success?, 'Suite totals alone must not replace the identity/cancellation cases'
    refute execute.call(lines.join("\n"), summary).success?, 'Flags/case lines alone must not replace actual suite totals'
    refute execute.call(lines.join("\n") + "\n" + suite, summary.merge('skippedTests' => 1)).success?
    refute execute.call(lines.join("\n") + "\n" + suite, summary.merge('failedTests' => 1)).success?
    refute File.exist?(File.expand_path('../.github/workflows/player-seek-identity.yml', __dir__))
  end

  def test_ffi_artifact_jobs_have_no_skipped_success_rows_and_keep_device_link_owner
    ffi = YAML.load_file(File.expand_path('../.github/workflows/converter-ffi.yml', __dir__))
    artifacts = ffi.fetch('jobs').fetch('artifact-build')
    assert_equal %w[aarch64-apple-ios-sim x86_64-apple-ios], artifacts.fetch('strategy').fetch('matrix').fetch('include').map { |entry| entry.fetch('rust_target') }.sort
    refute artifacts.key?('if')
    commands = artifacts.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    refute_includes commands, 'exit 0'
    assert_includes commands, 'native_job.rb build -- cargo build --locked'
    assert_includes commands, 'test -f "$artifact"'
    codeql = YAML.load_file(File.expand_path('../.github/workflows/codeql.yml', __dir__))
    matrices = codeql.fetch('jobs').fetch('swift').fetch('strategy').fetch('matrix').fetch('include')
    ios = matrices.find { |entry| entry['platform'] == 'iOS' }
    assert_equal 'generic/platform=iOS', ios.fetch('destination')
    assert_equal 'build', ios.fetch('action')
  end

  def test_faber_uses_official_prebuilt_ruby_for_intel_only
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    mac = faber.fetch('jobs').fetch('macos-preferences')
    steps = mac.fetch('steps')
    assert_equal "${{ matrix.arch == 'x86_64' && inputs.intel_prebuilt && 'python' || matrix.arch == 'x86_64' && 'python,rust' || 'python,rust,ruby' }}", mac.fetch('env').fetch('MISE_ENABLE_TOOLS')
    setup = steps.find { |step| step['name'] == 'Install official prebuilt Ruby for Intel' }
    verify = steps.find { |step| step['name'] == 'Verify official Intel Ruby selection through mise' }
    install = steps.find { |step| step['run'] == 'mise install' }
    [setup, verify, install].each { |step| refute_nil step }
    [setup, verify].each { |step| assert_equal "matrix.arch == 'x86_64'", step.fetch('if') }
    assert_pinned_action('ruby/setup-ruby', setup.fetch('uses'))
    assert_equal({ 'ruby-version' => '4.0.7', 'bundler-cache' => false }, setup.fetch('with'))
    assert_operator steps.index(steps.find { |step| step['uses'].to_s.start_with?('jdx/mise-action@') }), :<, steps.index(setup)
    assert_operator steps.index(setup), :<, steps.index(install)
    assert_operator steps.index(install), :<, steps.index(verify)
    check = verify.fetch('run')
    assert_includes check, 'RUBY_VERSION == "4.0.7"'
    assert_includes check, 'RbConfig::CONFIG.fetch("host_cpu") == "x86_64"'
    assert_includes check, 'File.realpath(RbConfig.ruby)'
    assert_includes check, 'RUNNER_TOOL_CACHE'
    assert_includes check, 'mise exec -- ruby'
    assert_includes check, 'cmp "$RUNNER_TEMP/faber-ruby-direct.txt" "$RUNNER_TEMP/faber-ruby-mise.txt"'
    refute steps.any? { |step| step['id'].to_s.start_with?('ruby-cache') || step['name'].to_s.match?(/Ruby.*cache/i) }
    assert_equal ['macos-15', 'macos-15-intel'], selected_faber_matrix(faber, event_name: 'workflow_call', workflow_inputs: {}).map { |entry| entry.fetch('os') }
  end

  def test_faber_intel_rust_cache_is_toolchain_scoped_and_saved_only_after_architecture_validation
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    steps = faber.fetch('jobs').fetch('macos-preferences').fetch('steps')
    identity = steps.find { |step| step['id'] == 'rust-cache-identity' }
    restore = steps.find { |step| step['id'] == 'rust-cache' }
    build = steps.find { |step| step['id'] == 'ffi-build' }
    verify = steps.find { |step| step['id'] == 'ffi-architecture' }
    save = steps.find { |step| step['name'] == 'Save Intel Rust build cache' }
    [identity, restore, build, verify, save].each { |step| refute_nil step }
    [identity, restore].each { |step| assert_equal "matrix.arch == 'x86_64' && !inputs.intel_prebuilt", step.fetch('if') }
    assert_pinned_action('actions/cache/restore', restore.fetch('uses'))
    assert_pinned_action('actions/cache/save', save.fetch('uses'))
    paths = ["~/.cargo/registry", 'target/release', 'target/espeak-data']
    [restore, save].each { |step| assert_equal paths, step.fetch('with').fetch('path').lines.map(&:strip) }
    refute_includes paths, 'target'
    refute paths.any? { |path| path.include?('onnxruntime') }
    key = restore.fetch('with').fetch('key')
    %w[runner.arch steps.rust-cache-identity.outputs.identity].each do |identity_key|
      assert_includes key, "${{ #{identity_key} }}"
    end
    ["hashFiles('Cargo.lock'", "'**/Cargo.toml'", "'.cargo/config.toml'", "'mise.toml'",
      "'scripts/native_job.rb'", "'scripts/native_build_command.rb'", "'crates/**/*.rs'",
      "'native/**/*.rs'", "'native/**/*.cpp'", "'native/vendor/espeak-rs-sys/espeak-ng/**'"]
      .each { |input| assert_includes key, input }
    restore_prefix = restore.fetch('with').fetch('restore-keys')
    assert_includes restore_prefix, '${{ runner.arch }}'
    assert_includes restore_prefix, "'Cargo.lock'"
    refute_includes restore_prefix, "'crates/**/*.rs'"
    assert_equal "${{ steps.rust-cache.outputs.cache-primary-key }}", save.fetch('with').fetch('key')
    assert_match(/matrix\.arch == 'x86_64'/, save.fetch('if'))
    assert_includes save.fetch('if'), '!inputs.intel_prebuilt'
    assert_includes save.fetch('if'), 'success()'
    assert_includes save.fetch('if'), "steps.rust-cache.outputs.cache-hit != 'true'"
    assert_includes save.fetch('if'), "steps.ffi-build.outcome == 'success'"
    assert_includes save.fetch('if'), "steps.ffi-architecture.outcome == 'success'"
    assert_equal "matrix.arch != 'x86_64' || !inputs.intel_prebuilt", build.fetch('if')
    refute verify.key?('if')
    assert_equal 'mise run converter-ffi:build', build.fetch('run')
    assert_includes verify.fetch('run'), 'xcrun lipo -archs target/release/libconverter_ffi.dylib'
    assert_includes identity.fetch('run'), 'rustc -vV'
    assert_includes identity.fetch('run'), 'cargo --version'
    assert_includes identity.fetch('run'), 'xcodebuild -version'
    assert_includes identity.fetch('run'), 'ImageOS'
    assert_includes identity.fetch('run'), 'ImageVersion'
    assert_includes identity.fetch('run'), '--show-sdk-path'
    assert_includes identity.fetch('run'), '--show-sdk-version'
    assert_includes identity.fetch('run'), 'clang_sha256'
    %w[MACOSX_DEPLOYMENT_TARGET=12.0 ORT_PREFER_DYNAMIC_LINK=1 CARGO_BUILD_JOBS=1].each do |flag|
      assert_includes identity.fetch('run'), flag
    end
    assert_operator steps.index(identity), :<, steps.index(restore)
    assert_operator steps.index(restore), :<, steps.index(build)
    assert_operator steps.index(build), :<, steps.index(verify)
    assert_operator steps.index(verify), :<, steps.index(save)
  end

  def test_faber_intel_prebuilt_is_opt_in_and_has_no_rust_build_fallback
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    triggers = faber.fetch('on', faber[true])
    %w[workflow_call workflow_dispatch].each do |event|
      inputs = triggers.fetch(event).fetch('inputs')
      assert_equal false, inputs.fetch('intel_prebuilt').fetch('default')
      assert_equal '', inputs.fetch('intel_prebuilt_run_id').fetch('default')
      assert_equal '', inputs.fetch('intel_prebuilt_run_attempt').fetch('default')
    end
    assert_equal 'read', faber.fetch('permissions').fetch('actions')
    steps = faber.fetch('jobs').fetch('macos-preferences').fetch('steps')
    download = steps.find { |step| step['name'] == 'Download and verify the pinned Intel converter-ffi artifact' }
    build = steps.find { |step| step['id'] == 'ffi-build' }
    verify = steps.find { |step| step['id'] == 'ffi-architecture' }
    assert_equal "matrix.arch == 'x86_64' && inputs.intel_prebuilt", download.fetch('if')
    assert_includes download.fetch('run'), 'test -n "$FFI_RUN_ID"'
    assert_includes download.fetch('run'), 'test -n "$FFI_RUN_ATTEMPT"'
    assert_includes download.fetch('run'), 'mise run onnxruntime:host'
    assert_includes download.fetch('run'), 'scripts/download_converter_ffi_macos.rb'
    assert_equal "matrix.arch != 'x86_64' || !inputs.intel_prebuilt", build.fetch('if')
    refute verify.key?('if')
    assert_operator steps.index(download), :<, steps.index(verify)
    assert_operator steps.index(build), :<, steps.index(verify)
  end
end
