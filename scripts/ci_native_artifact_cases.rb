# frozen_string_literal: true

# Loaded by test_ci_runtime_scope.rb; preserve the existing suite selectors and fixture.
class CiRuntimeScopeTest
  def test_windows_reader_chooses_local_import_before_waiting_for_the_native_picker
    script_lines = File.readlines(File.expand_path('verify_windows_reader_gui.ps1', __dir__))
    journey = [
      /Click-FlutterElement \$addBook/,
      /\$importFile = Wait-ForReaderUi .*Find-AppText '\^Import an EPUB or PDF file\$'/,
      /Click-FlutterElement \$importFile/,
      /\$dialog = Wait-ForReaderUi 'the native file picker'/
    ]
    positions = journey.map { |step| script_lines.index { |line| step.match?(line) } }
    journey.zip(positions).each { |step, position| refute_nil position, "Missing journey step #{step.inspect}" }
    assert positions.each_cons(2).all? { |before, after| before < after }, 'Wait for the native picker after choosing local import'
  end

  def test_windows_reader_content_is_verified_from_the_app_trace_not_the_accessibility_tree
    script = File.read(File.expand_path('verify_windows_reader_gui.ps1', __dir__))
    assert_includes script, '$env:EPUB2MP3_UI_TRACE = $tracePath'
    assert_operator script.index('$env:EPUB2MP3_UI_TRACE'), :<, script.index('Start-Process -FilePath $executable')
    assert_match(/Wait-ForTraceEvent 'the opening chapter passage' 'reader.chapter'/, script)
    assert_match(/Wait-ForTraceEvent 'the second chapter passage' 'reader.chapter'/, script)
    refute_match(/Find-AppText 'a neblina cobria a colina'/, script)
    refute_match(/Find-AppText 'um mapa antigo, dobrado'/, script)
  end

  def test_windows_faber_retains_only_the_verified_release_bundle_as_a_separate_artifact
    workflow = YAML.load_file(File.expand_path('../.github/workflows/flutter-rust-faber.yml', __dir__))
    job = workflow.fetch('jobs').fetch('windows-package-faber')
    assert_equal 'windows-2025', job.fetch('runs-on')
    steps = job.fetch('steps')
    conversion = steps.find { |step| step['name'] == 'Convert exactly two chapters through the packaged Windows DLL' }
    package = steps.find { |step| step['name'] == 'Retain the verified Windows package' }
    logs = steps.find { |step| step.dig('with', 'name') == 'dart-rust-faber-windows' }
    gui = steps.find { |step| step['name'] == 'Exercise the packaged Windows reader on the native desktop' }
    [conversion, gui, package, logs].each { |step| refute_nil step }
    assert_operator steps.index(conversion), :<, steps.index(gui)
    assert_operator steps.index(gui), :<, steps.index(package)
    refute gui.key?('continue-on-error')
    run = gui.fetch('run')
    assert_includes run, '-STA -File scripts/verify_windows_reader_gui.ps1'
    assert_includes run, "-Package 'flutter_app/build/windows/x64/runner/Release'"
    assert_includes run, "-Fixture 'tests/fixtures/epubs/cli_faber_public_chapters.epub'"
    assert_includes run, "-Evidence '.reports/windows-faber/reader-gui'"
    assert_equal 'success()', package.fetch('if')
    assert_pinned_action 'actions/upload-artifact', package.fetch('uses')
    assert_equal 'flutter-windows-x64-${{ github.sha }}', package.dig('with', 'name')
    assert_equal 'flutter_app/build/windows/x64/runner/Release/', package.dig('with', 'path')
    assert_equal 'error', package.dig('with', 'if-no-files-found')
    assert_equal 7, package.dig('with', 'retention-days')
    assert_equal 'always()', logs.fetch('if')
    assert_equal '.reports/windows-faber', logs.dig('with', 'path')
  end

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
    refute artifacts.key?('strategy'), 'Both simulator targets build in one job so they need one macOS runner, not two'
    assert_equal 'macos-15', artifacts.fetch('runs-on')
    refute artifacts.key?('if')
    commands = artifacts.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    assert_equal 2, commands.scan('for rust_target in aarch64-apple-ios-sim x86_64-apple-ios; do').size
    assert_includes commands, 'rustup target add aarch64-apple-ios-sim x86_64-apple-ios'
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
    assert_equal "${{ matrix.arch == 'x86_64' && inputs.intel_prebuilt && 'aqua:git-lfs/git-lfs' || matrix.arch == 'x86_64' && 'rust' || 'rust,ruby' }}", mac.fetch('env').fetch('MISE_ENABLE_TOOLS')
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

  def test_faber_rust_cache_covers_both_architectures_is_toolchain_scoped_and_saved_only_on_master_after_validation
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    steps = faber.fetch('jobs').fetch('macos-preferences').fetch('steps')
    identity = steps.find { |step| step['id'] == 'rust-cache-identity' }
    restore = steps.find { |step| step['id'] == 'rust-cache' }
    build = steps.find { |step| step['id'] == 'ffi-build' }
    verify = steps.find { |step| step['id'] == 'ffi-architecture' }
    save = steps.find { |step| step['name'] == 'Save Rust build cache on master' }
    [identity, restore, build, verify, save].each { |step| refute_nil step }
    [identity, restore].each { |step| assert_equal "matrix.arch != 'x86_64' || !inputs.intel_prebuilt", step.fetch('if') }
    assert_pinned_action('actions/cache/restore', restore.fetch('uses'))
    assert_pinned_action('actions/cache/save', save.fetch('uses'))
    paths = ["~/.cargo/registry", 'target/release', 'target/espeak-data']
    [restore, save].each { |step| assert_equal paths, step.fetch('with').fetch('path').lines.map(&:strip) }
    refute_includes paths, 'target'
    refute paths.any? { |path| path.include?('onnxruntime') }
    key = restore.fetch('with').fetch('key')
    assert key.start_with?('faber-rust-${{ matrix.os }}-${{ runner.arch }}-'), 'Runner OS and architecture select the cache'
    %w[matrix.os runner.arch steps.rust-cache-identity.outputs.identity].each do |identity_key|
      assert_includes key, "${{ #{identity_key} }}"
    end
    ["hashFiles('Cargo.lock'", "'**/Cargo.toml'", "'.cargo/config.toml'", "'mise.toml'",
      "'scripts/native_job.rb'", "'scripts/native_build_command.rb'",
      "'native/**/*.cpp'", "'native/vendor/espeak-rs-sys/espeak-ng/**'"]
      .each { |input| assert_includes key, input }
    restore_prefix = restore.fetch('with').fetch('restore-keys')
    assert_includes restore_prefix, '${{ runner.arch }}'
    assert_includes restore_prefix, "'Cargo.lock'"
    refute_includes key, "'crates/**/*.rs'"
    refute_includes restore_prefix, "'native/**/*.cpp'"
    assert_equal "${{ steps.rust-cache.outputs.cache-primary-key }}", save.fetch('with').fetch('key')
    assert_includes save.fetch('if'), "(matrix.arch != 'x86_64' || !inputs.intel_prebuilt)"
    assert_includes save.fetch('if'), "github.ref == 'refs/heads/master'"
    assert_includes save.fetch('if'), 'success()'
    assert_includes save.fetch('if'), "steps.rust-cache.outputs.cache-hit != 'true'"
    assert_includes save.fetch('if'), "steps.ffi-build.outcome == 'success'"
    assert_includes save.fetch('if'), "steps.ffi-architecture.outcome == 'success'"
    assert_equal "matrix.arch != 'x86_64' || !inputs.intel_prebuilt", build.fetch('if')
    refute verify.key?('if')
    assert_equal 'mise run converter-ffi:build', build.fetch('run')
    assert_includes verify.fetch('run'), 'xcrun lipo -archs target/release/libconverter_ffi.dylib'
    assert_equal "${{ matrix.arch == 'arm64' }}", identity.fetch('env').fetch('IMAGE_BUILD_AGNOSTIC')
    assert_equal 1, restore_prefix.lines.map(&:strip).reject(&:empty?).size, 'No fallback crosses lockfile or build-script edits'
    producer = YAML.load_file(File.expand_path('../.github/workflows/converter-ffi-macos-intel-prebuilt.yml', __dir__))
    shared = producer.fetch('jobs').fetch('build').fetch('steps').find { |step| step['id'] == 'rust-cache-identity' }
    refute_nil shared
    intel_key = key.sub('${{ matrix.os }}', 'macos-15-intel')
    producer_cache = producer.fetch('jobs').fetch('build').fetch('steps').find { |step| step['uses'].to_s.start_with?('actions/cache') }
    assert_equal intel_key, producer_cache.fetch('with').fetch('key'), 'Intel Faber and the Intel FFI producer must share one cache key'
    assert_operator steps.index(identity), :<, steps.index(restore)
    assert_operator steps.index(restore), :<, steps.index(build)
    assert_operator steps.index(build), :<, steps.index(verify)
    assert_operator steps.index(verify), :<, steps.index(save)
  end

  # Executes the actual identity step against fake host tools.
  def test_faber_arm64_identity_ignores_the_image_build_but_not_the_toolchain_or_cmake
    require 'tmpdir'
    require 'open3'
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    run = faber.fetch('jobs').fetch('macos-preferences').fetch('steps').find { |step| step['id'] == 'rust-cache-identity' }.fetch('run')
    Dir.mktmpdir('faber-identity-') do |root|
      bin = File.join(root, 'bin')
      Dir.mkdir(bin)
      clang = File.join(root, 'clang')
      File.write(clang, 'clang-v1')
      tools = {
        'mise' => 'shift 2; exec "$@"',
        'rustc' => 'echo "rustc 1.99.1"', 'cargo' => 'echo "cargo 1.99.1"',
        'xcodebuild' => 'printf "Xcode 16.4\nBuild version 16F6\n"',
        'xcrun' => 'case "$*" in *show-sdk-path*) echo /sdk;; *show-sdk-version*) echo 15.5;; *) echo "$FAKE_CLANG";; esac',
        'cmake' => 'echo "cmake version ${FAKE_CMAKE:-3.31.6}"'
      }
      tools.each do |name, body|
        File.write(File.join(bin, name), "#!/bin/bash\n#{body}\n")
        File.chmod(0o700, File.join(bin, name))
      end
      identity = lambda do |arch, image, cmake: '3.31.6'|
        output = File.join(root, 'github-output')
        File.write(output, '')
        environment = { 'PATH' => "#{bin}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", 'GITHUB_OUTPUT' => output,
          'IMAGE_BUILD_AGNOSTIC' => (arch == 'arm64').to_s, 'ImageOS' => 'macos15', 'ImageVersion' => image, 'FAKE_CMAKE' => cmake, 'FAKE_CLANG' => clang }
        _out, err, status = Open3.capture3(environment, 'bash', '-e', '-c', run, chdir: File.expand_path('..', __dir__))
        assert status.success?, err
        File.read(output)[/\Aidentity=(\h{64})\n\z/, 1] || flunk("Missing identity output: #{File.read(output)}")
      end
      assert_equal identity.call('arm64', '20261104.0514.1'), identity.call('arm64', '20261112.0539.3')
      refute_equal identity.call('arm64', '20261104.0514.1'), identity.call('arm64', '20261104.0514.1', cmake: '4.0.0')
      refute_equal identity.call('x86_64', '20261104.0514.1'), identity.call('x86_64', '20261112.0539.3'), 'Intel stays image-scoped for the producer'
      arm = identity.call('arm64', '20261104.0514.1')
      File.write(clang, 'clang-v2')
      refute_equal arm, identity.call('arm64', '20261104.0514.1'), 'The compiler binary still selects the cache'
    end
  end

  # The Piper test takes its job count only from the native_job.rb guard.
  def test_faber_piper_cancellation_cargo_test_runs_under_the_native_job_guard
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    step = faber.fetch('jobs').fetch('macos-preferences').fetch('steps').find { |entry| entry['name'] == 'Verify native Piper cancellation and subsequent inference' }
    refute_nil step
    run = step.fetch('run')
    cargo = run.lines.drop_while { |line| !line.include?('cargo test') }.take_while { |line| !line.strip.end_with?('--nocapture') }.join
    assert_includes run, 'mise exec -- ruby scripts/native_job.rb build -- cargo test --locked -p piper-runtime --release --lib'
    refute_match(/--jobs|-j\d|CARGO_BUILD_JOBS/, cargo)
    refute (step.fetch('env', {}).keys + faber.fetch('jobs').fetch('macos-preferences').fetch('env', {}).keys).include?('CARGO_BUILD_JOBS')
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
