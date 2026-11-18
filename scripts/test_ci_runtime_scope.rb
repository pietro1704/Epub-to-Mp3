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
  def assert_pinned_action(action, value)
    assert_match(/\A#{Regexp.escape(action)}@[0-9a-f]{40}(?:\s+#.*)?\z/, value)
  end

  def selected_faber_matrix(faber, event_name:, workflow_inputs:)
    expression = faber.fetch('jobs').fetch('macos-preferences').fetch('strategy').fetch('matrix').fetch('include')
    structure = /\A\$\{\{\s*fromJSON\(\s*inputs\.macos_only\s*==\s*true\s*&&\s*'(?<arm>\[[^']+\])'\s*\|\|\s*github\.event_name\s*==\s*'workflow_dispatch'\s*&&\s*inputs\.intel_only\s*==\s*true\s*&&\s*'(?<intel>\[[^']+\])'\s*\|\|\s*'(?<full>\[[^']+\])'\s*\)\s*\}\}\z/
    match = structure.match(expression)
    assert match, 'Matrix must select the explicit app gate or dispatch-only Intel mode before the full matrix'
    focused = event_name == 'workflow_dispatch' && workflow_inputs.fetch('intel_only', false) == true
    mode = workflow_inputs.fetch('macos_only', false) == true ? 'arm' : (focused ? 'intel' : 'full')
    JSON.parse(match[mode])
  end

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
    assert_equal %w[rust web flutter android wasm apple].to_h { |name| [name, 'false'] }, result
    assert_equal 'false', contracts
    guard = @workflow.fetch('jobs').fetch('production-packaging-guard')
    refute guard.key?('if')
    assert_equal 'changes', guard.fetch('needs')
    boundary = guard.fetch('steps').find { |step| step['name'] == 'Check production packaging boundary' }
    refute boundary.key?('if')
    assert_equal 'bash scripts/guard_no_python_production.sh', boundary.fetch('run')
    %w[rust web flutter android wasm apple contracts].each do |name|
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
      ['scripts/host_tool.py'], ['web/src/app.tsx'], ['flutter_app/lib/main.dart'],
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
    runtimes = %w[rust flutter android-jvm web apple-app]
    runtimes.each { |name| assert_equal ['changes'], Array(jobs.fetch(name).fetch('needs')), name }
    assert_equal (%w[changes production-packaging-guard] + runtimes).sort,
      jobs.fetch('pr-gate').fetch('needs').sort
    assert_equal 'always()', jobs.fetch('pr-gate').fetch('if')
  end

  def test_platform_and_shared_runtime_dependencies
    { 'web/src/app.tsx' => %w[web], 'flutter_app/lib/main.dart' => %w[flutter],
      'scripts/host_tool.py' => [], 'crates/converter-server/src/main.rs' => %w[rust],
      'ios/EpubToMp3/EpubToMp3/App/EpubToMp3App.swift' => %w[apple],
      'ios/EpubToMp3/Package.swift' => %w[apple],
      'native/piper-runtime/src/lib.rs' => %w[rust apple flutter android],
      'crates/converter-ffi/src/lib.rs' => %w[rust apple flutter android],
      'Cargo.lock' => %w[rust apple flutter android web wasm],
      'Cargo.toml' => %w[rust apple flutter android web wasm],
      'rust-toolchain.toml' => %w[rust apple flutter android web wasm],
      'mise.toml' => %w[rust apple flutter android web wasm],
      'mise.lock' => %w[rust apple flutter android web wasm],
      '.github/workflows/ci.yml' => %w[rust apple flutter android web wasm],
      '.github/workflows/post-merge-validation.yml' => %w[rust apple flutter android web wasm],
      '.github/workflows/browser-runtime.yml' => %w[web wasm],
      '.github/workflows/faber-integration.yml' => %w[rust apple flutter android web wasm],
      '.github/workflows/converter-ffi.yml' => %w[rust apple flutter android],
      '.github/actions/rust-build-cache/action.yml' => %w[rust apple flutter android web wasm],
      'scripts/build_web_wasm.sh' => %w[web wasm],
      'Cargo.lock.notes.md' => [],
      'crates/converter-core/src/lib.rs' => %w[rust apple flutter web wasm],
      'crates/converter-wasm/src/lib.rs' => %w[rust web wasm],
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

  def test_deleted_or_renamed_shared_source_keeps_its_consumers
    # --no-renames makes both the removed and new names visible to classification.
    result, status, err = scope(['crates/converter-core/src/deleted.rs', 'docs/moved.md'])
    assert status.success?, err
    assert_equal %w[apple flutter rust wasm web], result.select { |_, value| value == 'true' }.keys.sort
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

  def gate(scopes, results = {}, integrated = false)
    needs = { 'changes' => { 'result' => 'success', 'outputs' => scopes },
      'production-packaging-guard' => { 'result' => 'success' } }
    { 'rust' => 'rust', 'flutter' => 'flutter', 'android-jvm' => 'android', 'web' => 'web',
      'apple-app' => 'apple' }.each do |job, name|
      selected = scopes[name] == 'true' && !(%w[apple-app android-jvm].include?(job) && integrated == true)
      needs[job] = { 'result' => selected ? 'success' : 'skipped' }
    end
    results.each { |job, result| needs.fetch(job)['result'] = result }
    script = @workflow.fetch('jobs').fetch('pr-gate').fetch('steps').first.fetch('run')
    Open3.capture3({ 'NEEDS_JSON' => JSON.generate(needs), 'INTEGRATED_VALIDATION' => integrated.to_s }, RbConfig.ruby, '-e', script).last
  end

  def test_native_app_gate_rejects_failures_and_integrated_validation_avoids_duplicate_app_runs
    scopes = %w[rust web flutter android wasm apple].to_h { |name| [name, 'false'] }.merge('apple' => 'true')
    assert gate(scopes).success?
    %w[failure cancelled skipped].each { |result| refute gate(scopes, 'apple-app' => result).success? }
    assert gate(scopes, {}, true).success?
    refute gate(scopes, { 'apple-app' => 'success' }, true).success?
    refute gate(scopes, {}, 'unknown').success?
  end

  def test_gate_accepts_only_confirmed_scopes_and_matching_results
    scopes = %w[rust web flutter android wasm apple].to_h { |name| [name, 'false'] }.merge('web' => 'true')
    assert gate(scopes).success?
    %w[failure cancelled skipped].each { |result| refute gate(scopes, 'web' => result).success? }
    refute gate(scopes, 'changes' => 'failure').success?
    %w[failure cancelled skipped].each do |result|
      refute gate(scopes, 'production-packaging-guard' => result).success?
    end
    refute gate(scopes.reject { |name, _| name == 'rust' }).success?
    refute gate(scopes.reject { |name, _| name == 'wasm' }).success?
    refute gate(scopes.merge('wasm' => 'unknown')).success?
    refute gate(scopes.merge('web' => 'false', 'wasm' => 'true')).success?
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

  def test_pr_jobs_do_not_rebuild_unaffected_wasm
    refute @workflow.fetch('jobs').key?('python-tests')
    web = @workflow.fetch('jobs').fetch('web')
    %w[Install\ Rust\ WASM\ target Build\ direct\ Rust\ WASM\ adapter].each do |name|
      assert_equal "needs.changes.outputs.wasm == 'true'", web.fetch('steps').find { |step| step['name'] == name }.fetch('if')
    end
    assert_equal '0', @workflow.fetch('jobs').fetch('flutter').fetch('env').fetch('EPUB_DART_FABER_INTEGRATION')
    refute_includes @workflow.fetch('jobs').fetch('flutter').fetch('steps').filter_map { |step| step['run'] }.join("\n"), 'cargo build'
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
  jobs = faber.fetch('jobs')
  %w[ffi-jni android-package browser-runtime].each do |job|
    assert_equal "${{ inputs.macos_only != true && !(github.event_name == 'workflow_dispatch' && inputs.intel_only == true) }}", jobs.fetch(job).fetch('if')
  end
  refute jobs.fetch('macos-preferences').key?('if')
  group = faber.fetch('concurrency').fetch('group')
  assert_includes group, "github.event_name == 'workflow_dispatch'"
  assert_includes group, 'inputs.intel_only == true'
  assert_includes group, 'intel-only'
  assert_includes group, 'full'
  assert_includes group, 'app-gate'
end

def test_faber_intel_only_is_dispatch_only_and_leaves_reusable_calls_full
  faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
  events = faber.fetch('on', faber[true])
  dispatch_inputs = events.fetch('workflow_dispatch').fetch('inputs')
  assert_equal({ 'type' => 'boolean', 'default' => false }, dispatch_inputs.fetch('intel_only').slice('type', 'default'))
  refute events.fetch('workflow_call').fetch('inputs').key?('intel_only')

  expected_full = [
    { 'os' => 'macos-15', 'arch' => 'arm64' },
    { 'os' => 'macos-15-intel', 'arch' => 'x86_64' }
  ]
  expected_intel = [{ 'os' => 'macos-15-intel', 'arch' => 'x86_64' }]
  defaults = dispatch_inputs.to_h { |name, config| [name, config.fetch('default', false)] }
  assert_equal expected_full, selected_faber_matrix(faber, event_name: 'workflow_dispatch', workflow_inputs: defaults)
  assert_equal expected_intel, selected_faber_matrix(faber, event_name: 'workflow_dispatch', workflow_inputs: defaults.merge('intel_only' => true))

  call_inputs = events.fetch('workflow_call').fetch('inputs').to_h { |name, config| [name, config.fetch('default', false)] }
  assert_equal false, call_inputs.fetch('macos_only')
  refute dispatch_inputs.key?('macos_only')
  assert_equal [expected_full.first], selected_faber_matrix(faber, event_name: 'pull_request', workflow_inputs: call_inputs.merge('macos_only' => true))
  assert_equal expected_full, selected_faber_matrix(faber, event_name: 'workflow_dispatch', workflow_inputs: call_inputs),
    'A reusable caller event may be workflow_dispatch, but undeclared workflow_call inputs keep the full matrix'
  assert_equal expected_full, selected_faber_matrix(faber, event_name: 'pull_request', workflow_inputs: defaults.merge('intel_only' => true))

  post_merge = YAML.load_file(File.expand_path('../.github/workflows/post-merge-validation.yml', __dir__))
  assert_equal true, post_merge.fetch('jobs').fetch('ci').fetch('with').fetch('full_validation')
  refute post_merge.fetch('jobs').fetch('faber').fetch('with', {}).key?('intel_only')
end

def test_full_client_suites_replace_duplicate_subset_runs
  web_steps = @workflow.fetch('jobs').fetch('web').fetch('steps')
  flutter_steps = @workflow.fetch('jobs').fetch('flutter').fetch('steps')
  assert_includes web_steps.filter_map { |step| step['run'] }, 'mise exec -- npm test -- --maxWorkers=2'
  assert flutter_steps.any? { |step| step['run'].to_s.include?('mise run flutter:test') }
  [web_steps, flutter_steps].each do |steps|
    refute steps.any? { |step| step['run'].to_s.include?('bash scripts/check_direct_runtime_boundary.sh') }
  end
end

  def test_foundation_run_shares_the_apple_app_gate_runner
    app = @workflow.fetch('jobs').fetch('apple-app')
    integrated = "inputs.full_validation == true && github.ref == 'refs/heads/master' && contains(github.workflow_ref, '/.github/workflows/post-merge-validation.yml@')"
    assert_equal "needs.changes.outputs.apple == 'true' && !(#{integrated})", app.fetch('if')
    assert_equal "${{ #{integrated} }}", @workflow.fetch('jobs').fetch('pr-gate').fetch('steps').first.fetch('env').fetch('INTEGRATED_VALIDATION')
    assert_equal './.github/workflows/faber-integration.yml', app.fetch('uses')
    assert_equal({ 'macos_only' => true }, app.fetch('with'))
    refute File.exist?(File.expand_path('../.github/workflows/app-foundation-history.yml', __dir__))
    refute @workflow.fetch('jobs').key?('apple-foundation'), 'Foundation tests share the Apple app gate runner'
    refute_includes @workflow.fetch('jobs').fetch('pr-gate').fetch('needs'), 'apple-foundation'
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    mac = faber.fetch('jobs').fetch('macos-preferences')
    assert_equal '/Applications/Xcode_16.4.app/Contents/Developer', mac.fetch('env').fetch('DEVELOPER_DIR')
    assert_includes mac.fetch('env').fetch('MISE_ENABLE_TOOLS'), "'python,rust,ruby'"
    foundation = mac.fetch('steps').find { |step| step['name'] == 'Test the Foundation-only Apple production seam' }
    refute_nil foundation
    assert_equal "matrix.arch == 'arm64'", foundation.fetch('if')
    assert_includes foundation.fetch('run'), 'mise run apple:foundation:test'
    assert_includes foundation.fetch('run'), 'set -o pipefail'
    history = mac.fetch('steps').find { |step| step['name'] == 'Require the conversion history regression suite' }
    refute_nil history
    assert_equal "matrix.arch == 'arm64'", history.fetch('if')
    assert_operator mac.fetch('steps').index(foundation), :<, mac.fetch('steps').index(history)
    assert_equal [{ 'os' => 'macos-15', 'arch' => 'arm64' }], selected_faber_matrix(faber, event_name: 'pull_request', workflow_inputs: { 'macos_only' => true })
    evidence = File.join(@root, '.reports/tts-preferences')
    FileUtils.mkdir_p(evidence)
    execute = lambda do |log|
      File.write(File.join(evidence, 'apple-foundation-test.log'), log)
      Open3.capture3(RbConfig.ruby, '-e', history.fetch('run'), chdir: @root).last
    end
    suite = "Test Suite 'ConversionHistoryReaderTests' passed at 2026-10-20.\n  Executed 4 tests, with 0 failures (0 unexpected) in 0.003 seconds\n"
    assert execute.call(suite).success?
    refute execute.call(suite.sub('4 tests', '0 tests')).success?
    refute execute.call(suite.sub('with 0 failures', 'with 1 test skipped and 0 failures')).success?
    refute execute.call(suite + "Test Case '-[AppFoundationTests.ConversionHistoryReaderTests testHistory]' skipped (0.001 seconds).\n").success?

    faber_commands = mac.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    artifact = faber.fetch('jobs').fetch('macos-preferences').fetch('steps').find { |step| step['name'] == 'Retain macOS XCTest evidence' }
    assert_equal "${{ inputs.macos_only == true && 'apple-app-gate' || 'faber-macos-prefs' }}-${{ matrix.arch }}", artifact.fetch('with').fetch('name')
    %w[build-for-testing test-without-building].each do |action|
      assert_includes faber_commands, "ruby ../../scripts/native_job.rb build -- xcodebuild #{action}"
    end

    package = File.read(File.expand_path('../ios/EpubToMp3/Package.swift', __dir__))
    assert_includes package, '"Features/Conversion/Services/SpeechModelLibraryClient.swift"'
    assert_includes package, '"Shared/Configuration/LocalSpeechModelReadiness.swift"'
  end

  def test_physical_android_fixture_requires_explicit_input_instead_of_inherited_dispatch
    faber = YAML.load_file(File.expand_path('../.github/workflows/faber-integration.yml', __dir__))
    steps = faber.fetch('jobs').fetch('android-package').fetch('steps')
    fixture = steps.find { |step| step['id'] == 'device-fixture-apk' }
    assert_equal 'inputs.physical_fixture_apk == true', fixture.fetch('if')
    events = faber.fetch('on', faber[true])
    %w[workflow_call workflow_dispatch].each do |event|
      input = events.fetch(event).fetch('inputs').fetch('physical_fixture_apk')
      assert_equal 'boolean', input.fetch('type')
      assert_equal false, input.fetch('default')
    end
    refute steps.find { |step| step['id'] == 'main-ui-apk' }.key?('if')
    refute steps.find { |step| step['name'] == 'Run actual Piper inference in the packaged ARM64 app' }.key?('if')
    assert_includes fixture.fetch('run'), 'android_real_books_inference_test.dart'
    retention = steps.find { |step| step['name'] == 'Retain the physical-device fixture APK and build identity' }
    assert_includes retention.fetch('if'), "steps.device-fixture-apk.outcome == 'success'"
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

  def test_android_and_desktop_setup_use_project_flutter_without_unpinned_composite_actions
    root = File.expand_path('..', __dir__)
    codeql = YAML.load_file(File.join(root, '.github/workflows/codeql.yml'))
    release = YAML.load_file(File.join(root, '.github/workflows/release-desktop.yml'))
    jobs = [codeql.fetch('jobs').fetch('java-kotlin'), release.fetch('jobs').fetch('android'),
            release.fetch('jobs').fetch('flutter-desktop')]
    assert_match(/^flutter = \{ version = "3\.47\.9", os = \["linux", "windows"\] \}$/, File.read(File.join(root, 'mise.toml')))
    jobs.each do |job|
      steps = job.fetch('steps')
      # The old pinned Flutter composite still expanded actions/cache@v5 before
      # any step ran, which violates the repository's full-SHA action policy.
      refute steps.any? { |step| step.fetch('uses', '').start_with?('subosito/flutter-action@') }
      setup = steps.find { |step| step['name'] == 'Set up native build tools' || step['name'] == 'Setup Flutter' }
      assert_pinned_action 'jdx/mise-action', setup.fetch('uses')
      assert_includes setup.fetch('env').fetch('MISE_ENABLE_TOOLS').split(','), 'flutter'
      refute_equal false, setup.fetch('with').fetch('install', true)
      build = steps.find { |step| %w[Build\ Android\ app Build\ APK\ (release) Build].include?(step['name']) }
      scope = build.fetch('env', {}).fetch('MISE_ENABLE_TOOLS', job.fetch('env', {}).fetch('MISE_ENABLE_TOOLS', ''))
      assert_includes scope.split(','), 'flutter'
      assert_operator steps.index(setup), :<, steps.index(build)
    end
  end

  def test_scoped_pr_host_contract_budget_is_ten_minutes_with_parallel_runtime_jobs
    jobs = @workflow.fetch('jobs')
    assert_equal 2, jobs.fetch('changes').fetch('timeout-minutes')
    assert_equal 7, jobs.fetch('production-packaging-guard').fetch('timeout-minutes')
    assert_equal 1, jobs.fetch('pr-gate').fetch('timeout-minutes')
    %w[rust web flutter].each do |name|
      assert_equal '${{ inputs.full_validation == true && 30 || 7 }}', jobs.fetch(name).fetch('timeout-minutes')
      assert_includes jobs.fetch(name).fetch('needs'), 'changes'
      refute_includes jobs.fetch(name).fetch('needs'), 'production-packaging-guard'
    end
    assert_equal 10, jobs.fetch('changes').fetch('timeout-minutes') +
                     jobs.fetch('production-packaging-guard').fetch('timeout-minutes') +
                     jobs.fetch('pr-gate').fetch('timeout-minutes')
  end

end

require_relative "ci_native_artifact_cases"

require_relative "ci_flutter_android_cases"
