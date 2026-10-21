# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'shellwords'
require_relative 'run_ci_contracts'

class CiRuntimeScopeTest < Minitest::Test
  def setup
    @workflow = YAML.load_file(File.expand_path('../.github/workflows/ci.yml', __dir__))
    @root = Dir.mktmpdir('ci-scope-contract-')
    @git = File.join(@root, 'git')
    File.write(@git, "#!/bin/sh\n[ \"$1\" = diff ] || exit 63\ncase \" $* \" in *\" --no-renames \"*) ;; *) exit 64 ;; esac\nprintf '%s' \"$FIXTURE_PATHS\" | tr '\\n' '\\000'\nexit \"${FIXTURE_GIT_EXIT:-0}\"\n")
    File.chmod(0o700, @git)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def scope(paths, full: false, base: 'a' * 40, event: 'pull_request', git_exit: '0')
    script = @workflow.fetch('jobs').fetch('changes').fetch('steps').find { |step| step['id'] == 'scope' }.fetch('run')
    output = File.join(@root, 'output')
    File.write(output, '')
    _, err, status = Open3.capture3({ 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'FULL_VALIDATION' => full.to_s,
      'EVENT_NAME' => event, 'BASE_SHA' => base, 'GITHUB_OUTPUT' => output,
      'FIXTURE_PATHS' => paths.join("\n"), 'FIXTURE_GIT_EXIT' => git_exit }, RbConfig.ruby, '-e', script)
    outputs = File.readlines(output, chomp: true).to_h { |line| line.split('=', 2) }
    contracts = outputs.delete('contracts')
    [outputs, status, err, contracts]
  end

  def test_documentation_changes_skip_runtimes_and_host_contracts_but_not_packaging
    result, status, err, contracts = scope(['docs/guide.md'])
    assert status.success?, err
    assert_equal %w[rust web flutter python wasm].to_h { |name| [name, 'false'] }, result
    assert_equal 'false', contracts
    guard = @workflow.fetch('jobs').fetch('production-packaging-guard')
    refute guard.key?('if')
    assert_equal 'changes', guard.fetch('needs')
    boundary = guard.fetch('steps').find { |step| step['name'] == 'Check production packaging boundary' }
    refute boundary.key?('if')
    assert_equal 'bash scripts/guard_no_python_production.sh', boundary.fetch('run')
    %w[rust web flutter python wasm contracts].each do |name|
      assert_equal "${{ steps.scope.outputs.#{name} }}", @workflow.fetch('jobs').fetch('changes').fetch('outputs').fetch(name)
    end
  end

  def test_only_explicit_documentation_paths_skip_host_contracts
    [['README.md'], ['CHANGELOG.md'], ['docs/reader guide.md'], ['README.md', 'docs/agents/runtime.md']].each do |paths|
      _, status, err, contracts = scope(paths)
      assert status.success?, err
      assert_equal 'false', contracts, paths.inspect
    end
    [[], ['AGENTS.md'], ['mise.toml'], ['docs/generator.rb'], ['unknown.file'],
      ['python_app/source.py'], ['web/src/app.tsx'], ['flutter_app/lib/main.dart'],
      ['README.md', 'scripts/run_ci_contracts.rb'], ['scripts/deleted.rb', 'docs/moved.md']].each do |paths|
      _, status, err, contracts = scope(paths)
      assert status.success?, err
      assert_equal 'true', contracts, paths.inspect
    end
  end

  def test_guard_rejects_missing_or_malformed_host_contract_selection
    steps = @workflow.fetch('jobs').fetch('production-packaging-guard').fetch('steps')
    selection = steps.find { |step| step['name'] == 'Require explicit host contract selection' }
    refute_nil selection
    refute selection.key?('if')
    assert_equal '${{ needs.changes.outputs.contracts }}', selection.fetch('env').fetch('HOST_CONTRACTS')
    %w[true false].each do |value|
      assert Open3.capture3({ 'HOST_CONTRACTS' => value }, 'bash', '-c', selection.fetch('run')).last.success?
    end
    ['', 'TRUE', 'unknown'].each do |value|
      refute Open3.capture3({ 'HOST_CONTRACTS' => value }, 'bash', '-c', selection.fetch('run')).last.success?
    end
    names = ['Set up Ruby for host workflow checks', 'Install host test dependency',
      'Set up mise for task metadata checks', 'Install scoped host contract tools',
      'Install fixture-only Python dependencies', 'Verify host workflow guards and collaboration regressions']
    names.each do |name|
      step = steps.find { |entry| entry['name'] == name }
      assert_equal "needs.changes.outputs.contracts == 'true'", step.fetch('if'), name
      assert_operator steps.index(selection), :<, steps.index(step)
    end
  end

  def test_runtime_jobs_can_start_before_contracts_finish_but_gate_waits_for_both
    jobs = @workflow.fetch('jobs')
    runtimes = %w[python-tests rust flutter web]
    runtimes.each { |name| assert_equal ['changes'], Array(jobs.fetch(name).fetch('needs')), name }
    assert_equal (%w[changes production-packaging-guard] + runtimes).sort,
      jobs.fetch('pr-gate').fetch('needs').sort
    assert_equal 'always()', jobs.fetch('pr-gate').fetch('if')
  end

  def test_platform_and_shared_runtime_dependencies
    { 'web/src/app.tsx' => %w[web], 'flutter_app/lib/main.dart' => %w[flutter],
      'python_app/src/converter.py' => %w[python], 'crates/converter-server/src/main.rs' => %w[rust],
      'native/piper-runtime/src/lib.rs' => %w[rust],
      'Cargo.lock' => %w[rust], '.github/workflows/ci.yml' => [],
      'crates/converter-core/src/lib.rs' => %w[rust], 'crates/converter-wasm/src/lib.rs' => %w[rust web wasm],
      'web/src/wasm/converter_wasm.js' => %w[web wasm] }.each do |path, expected|
      result, status, err = scope([path])
      assert status.success?, err
      assert_equal expected.sort, result.select { |_, value| value == 'true' }.keys.sort, path
    end
  end

  def test_multi_file_and_deleted_paths_are_classified
    result, status, err = scope(['docs/removed.md', 'web/src/deleted.ts', 'flutter_app/lib/new.dart'])
    assert status.success?, err
    assert_equal %w[flutter web], result.select { |_, value| value == 'true' }.keys.sort
  end

  def test_full_validation_uses_every_runtime_without_pr_context
    result, status, err, contracts = scope(['README.md'], full: true, base: '', event: 'push')
    assert status.success?, err
    assert result.values.all? { |value| value == 'true' }
    assert_equal 'true', contracts
  end

  def test_missing_identity_and_failed_diff_fail_closed
    [['', '0'], ['a' * 40, '1'], ['refs/heads/master', '0']].each do |base, exit_code|
      result, status, _, contracts = scope(['README.md'], base: base, git_exit: exit_code)
      refute status.success?
      assert_empty result
      assert_nil contracts
    end
  end

  def test_manual_scoped_validation_requires_explicit_base
    _, status, err = scope(['web/app.ts'], event: 'workflow_dispatch')
    assert status.success?, err
    _, status, = scope([], event: 'workflow_dispatch', base: '')
    refute status.success?
  end

  def gate(scopes, results = {})
    needs = { 'changes' => { 'result' => 'success', 'outputs' => scopes },
      'production-packaging-guard' => { 'result' => 'success' } }
    { 'python-tests' => 'python', 'rust' => 'rust', 'flutter' => 'flutter', 'web' => 'web' }.each do |job, name|
      needs[job] = { 'result' => scopes[name] == 'true' ? 'success' : 'skipped' }
    end
    results.each { |job, result| needs.fetch(job)['result'] = result }
    script = @workflow.fetch('jobs').fetch('pr-gate').fetch('steps').first.fetch('run')
    Open3.capture3({ 'NEEDS_JSON' => JSON.generate(needs) }, RbConfig.ruby, '-e', script).last
  end

  def test_gate_accepts_only_confirmed_scopes_and_matching_results
    scopes = %w[rust web flutter python wasm].to_h { |name| [name, 'false'] }.merge('web' => 'true')
    assert gate(scopes).success?
    %w[failure cancelled skipped].each { |result| refute gate(scopes, 'web' => result).success? }
    refute gate(scopes, 'changes' => 'failure').success?
    %w[failure cancelled skipped].each do |result|
      refute gate(scopes, 'production-packaging-guard' => result).success?
    end
    refute gate(scopes.reject { |name, _| name == 'rust' }).success?
    refute gate(scopes, 'rust' => 'success').success?
  end
  def test_redundant_workflows_have_concrete_replacements
    workflows = File.expand_path('../.github/workflows', __dir__)
    refute File.exist?(File.join(workflows, 'rust-format-preview.yml'))
    refute File.exist?(File.join(workflows, 'dependabot-flush.yml'))
    rust_commands = @workflow.fetch('jobs').fetch('rust').fetch('steps').filter_map { |step| step['run'] }
    assert_includes rust_commands, 'mise exec -- cargo fmt --all -- --check'
    assert File.file?(File.join(workflows, 'auto-merge-dependabot.yml'))
    events = @workflow.fetch('on', @workflow[true])
    refute events.key?('push')
    assert_equal false, events.fetch('workflow_call').fetch('inputs').fetch('full_validation').fetch('default')
    assert_equal false, events.fetch('workflow_dispatch').fetch('inputs').fetch('full_validation').fetch('default')
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
    analyze = steps.find { |step| step['uses'] == 'github/codeql-action/analyze@v4' }
    assert_equal "${{ format('/language:swift/coverage:{0}/platform:{1}', matrix.coverage, matrix.platform) }}", analyze.fetch('with').fetch('category')
    refute analyze.fetch('with').key?('upload')
    project = YAML.load_file(File.expand_path('../ios/EpubToMp3/project.yml', __dir__))
    assert_equal 'all', project.fetch('schemes').fetch('EpubToMp3').fetch('build').fetch('targets').fetch('EpubToMp3')
    assert_equal ['test'], project.fetch('schemes').fetch('EpubToMp3').fetch('build').fetch('targets').fetch('EpubToMp3Tests')
  end

  def test_lightweight_python_reuses_contracts_from_the_required_guard
    guard = @workflow.fetch('jobs').fetch('production-packaging-guard')
    refute guard.key?('if')
    assert_includes @workflow.fetch('jobs').fetch('pr-gate').fetch('needs'), 'production-packaging-guard'
    assert guard.fetch('steps').any? { |step| step['run'].to_s.include?('ruby scripts/run_ci_contracts.rb') }
    guarded = CiContracts.steps.find { |step| step.fetch('name') == 'Python offline contracts' }.fetch('argv')
    steps = @workflow.fetch('jobs').fetch('python-tests').fetch('steps')
    lightweight = steps.find { |step| step['name'] == 'Validate legacy syntax, lint and offline consent contracts' }
    pytest = lightweight.fetch('run').lines.map { |line| Shellwords.split(line) }.find { |argv| argv.include?('pytest') }
    assert_includes pytest, 'python_app/tests/test_audio_pause_policy.py'
    %w[test_feature_ab_cache_isolation.py test_feature_ab_regression.py].each do |name|
      path = "python_app/tests/#{name}"
      assert_equal 1, guarded.count(path), path
      refute_includes pytest, path
    end
  end

  def test_flutter_sdk_cache_keeps_scope_checks_installation_and_validation_on_hits_and_misses
    steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
    cache = steps.find { |step| step['name'] == 'Cache Flutter SDK' }
    refute_nil cache
    assert_equal 'actions/cache@v6', cache.fetch('uses')
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

  def test_pr_jobs_do_not_install_legacy_models_or_rebuild_unaffected_wasm
    python_steps = @workflow.fetch('jobs').fetch('python-tests').fetch('steps')
    %w[Install\ Python\ dependencies Run\ Python\ tests Install\ system\ dependencies Install\ explicit\ pinned\ Faber\ model\ for\ offline\ CLI\ smoke].each do |name|
      assert_equal 'inputs.full_validation == true', python_steps.find { |step| step['name'] == name }.fetch('if'), name
    end
    lite = python_steps.find { |step| step['name'] == 'Install lightweight legacy validation dependencies' }
    assert_equal 'mise exec -- python -m pip install pytest ruff==0.6.9', lite.fetch('run')
    web = @workflow.fetch('jobs').fetch('web')
    %w[Install\ Rust\ WASM\ target Build\ direct\ Rust\ WASM\ adapter].each do |name|
      assert_equal "needs.changes.outputs.wasm == 'true'", web.fetch('steps').find { |step| step['name'] == name }.fetch('if')
    end
    assert_equal '0', @workflow.fetch('jobs').fetch('flutter').fetch('env').fetch('EPUB_DART_FABER_INTEGRATION')
    refute_includes @workflow.fetch('jobs').fetch('flutter').fetch('steps').filter_map { |step| step['run'] }.join("\n"), 'cargo build'
  end

  def test_shared_player_result_requires_real_cases_without_failures_or_skips
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    steps = faber.fetch('jobs').fetch('macos-preferences').fetch('steps')
    run = steps.find { |step| step['name'] == 'Run real macOS preference and installation XCTest' }.fetch('run')
    assert_includes run, '-only-testing:EpubToMp3Tests/AudioPlayerDivergenceTests'
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

def test_reusable_jobs_cannot_share_the_callers_concurrency_group
  groups = %w[converter-ffi flutter-rust-faber].map do |name|
    workflow = YAML.load_file(File.expand_path("../.github/workflows/#{name}.yml", __dir__))
    group = workflow.fetch('concurrency').fetch('group')
    assert group.start_with?("#{name}-"), 'Reusable workflows inherit github.workflow from the caller'
    group
  end
  assert_equal groups.size, groups.uniq.size
  faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
  %w[ffi-jni android-package macos-preferences browser-runtime].each { |job| refute faber.fetch('jobs').fetch(job).key?('if') }
end

def test_full_client_suites_replace_duplicate_subset_runs
  web_steps = @workflow.fetch('jobs').fetch('web').fetch('steps')
  flutter_steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
  assert_includes web_steps.filter_map { |step| step['run'] }, 'mise exec -- npm test -- --maxWorkers=2'
  assert_includes flutter_steps.filter_map { |step| step['run'] }, 'mise exec -- flutter test'
  [web_steps, flutter_steps].each do |steps|
    refute steps.any? { |step| step['run'].to_s.include?('bash scripts/check_direct_runtime_boundary.sh') }
  end
end

def test_shared_foundation_run_requires_executed_history_cases
  faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
  mac = faber.fetch('jobs').fetch('macos-preferences')
  assert_includes mac.fetch('strategy').fetch('matrix').fetch('include').map { |entry| entry.fetch('os') }, 'macos-15-intel'
  steps = mac.fetch('steps')
  original = steps.find { |step| step['name'] == 'Test the real Foundation package without native FFI opt-in' }.fetch('run')
  assert_includes original, 'mise run apple:foundation:test'
  script = steps.find { |step| step['name'] == 'Require the actual Foundation history suite in the shared package run' }.fetch('run')
  evidence = File.join(@root, '.reports/tts-preferences')
  FileUtils.mkdir_p(evidence)
  execute = lambda do |log|
    File.write(File.join(evidence, 'foundation.log'), log)
    Open3.capture3(RbConfig.ruby, '-e', script, chdir: @root).last
  end
  suite = "Test Suite 'ConversionHistoryReaderTests' passed at 2026-10-20.\n  Executed 4 tests, with 0 failures (0 unexpected) in 0.003 seconds\n"
  assert execute.call(suite).success?
  refute execute.call(suite.sub('4 tests', '0 tests')).success?
  refute execute.call(suite.sub('0 failures', '1 failures')).success?
  refute execute.call(suite.sub('with 0 failures', 'with 1 test skipped and 0 failures')).success?
  refute execute.call(suite.sub('ConversionHistoryReaderTests', 'UnrelatedTests')).success?
  refute execute.call(suite + "Test Case '-[AppFoundationTests.ConversionHistoryReaderTests testHistory]' skipped (0.001 seconds).\n").success?
  refute File.exist?(File.expand_path('../.github/workflows/app-foundation-history.yml', __dir__))
end

  def test_browser_runtime_has_an_independent_entrypoint_and_preserves_real_inference
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    assert_equal './.github/workflows/browser-runtime.yml', faber.fetch('jobs').fetch('browser-runtime').fetch('uses')
    browser = YAML.load_file(File.expand_path('../.github/workflows/browser-runtime.yml', __dir__))
    triggers = browser['on'] || browser[true]
    assert triggers.key?('workflow_call')
    assert triggers.key?('workflow_dispatch')
    assert_equal ['browser-runtime'], browser.fetch('jobs').keys
    steps = browser.fetch('jobs').fetch('browser-runtime').fetch('steps')
    development = steps.find { |step| step['name'] == 'Exercise real browser storage and development inference' }
    assert_includes development.fetch('run'), 'node web/scripts/verify-browser-tts.mjs'
    production = steps.find { |step| step['name'] == 'Exercise real production inference' }
    assert_equal 'production', production.fetch('env').fetch('TTS_BROWSER_MODE')
    assert_includes production.fetch('run'), 'node web/scripts/verify-browser-tts.mjs'
  end

end
