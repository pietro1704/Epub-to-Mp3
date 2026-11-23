# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

class RustBuildCacheTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def workflow(name)
    YAML.load_file(File.join(ROOT, '.github/workflows', name))
  end

  def test_cache_refreshes_source_changes_without_crossing_toolchain_or_job_boundaries
    action = YAML.load_file(File.join(ROOT, '.github/actions/rust-build-cache/action.yml'))
    steps = action.fetch('runs').fetch('steps')
    assert_equal 'composite', action.fetch('runs').fetch('using')
    assert_equal 'toolchain', steps.first.fetch('id')
    assert_includes steps.first.fetch('run'), 'rust-cache-identity.cjs'
    cache = steps.last
    assert_equal 'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9', cache.fetch('uses')
    options = cache.fetch('with')
    assert_equal ['~/.cargo/registry', '~/.cargo/git', "${{ inputs.cache-target == 'true' && 'target' || '' }}"],
                 options.fetch('path').lines.map(&:strip).reject(&:empty?)
    assert_equal 'true', action.fetch('inputs').fetch('cache-target').fetch('default')
    key = options.fetch('key')
    prefixes = options.fetch('restore-keys').lines.map(&:strip)
    [key, *prefixes].each do |entry|
      %w[runner.os runner.arch inputs.namespace steps.toolchain.outputs.identity].each do |boundary|
        assert_includes entry, "${{ #{boundary} }}"
      end
    end
    %w[Cargo.toml Cargo.lock .cargo/** mise.toml].each { |input| assert_includes key, "'#{input}'" }
    # Measured in CI run 45231415477: an exact key hit with identical sources still
    # recompiled every workspace crate, so a source hash only multiplies entries.
    refute_includes key, "'crates/**/*.rs'"
    assert_equal 1, prefixes.length
    assert key.start_with?(prefixes.first), 'Lockfile changes may reuse dependencies within the same toolchain'
    refute cache.key?('if'), 'A hit must never skip validation commands'
  end

  def test_every_adopted_job_restores_after_setup_and_still_runs_its_original_validation
    expected = {
      'native-fallback.yml' => {
        'linux-native' => ['native-fallback', 'mise exec -- cargo test --locked -p converter-core -p converter-ffi --features converter-ffi/android-jni'],
        'windows-native' => ['native-fallback', 'mise exec -- cargo test --locked -p converter-core --lib $contract']
      },
      'converter-ffi.yml' => {
        'host-validation' => ['ffi-host', 'mise exec -- cargo test -p converter-ffi'],
        'artifact-build' => ['ffi-ios-simulators', 'cargo build --locked -p converter-ffi --release']
      },
      'rust-dependency-audit.yml' => {
        'audit' => ['dependency-audit', 'mise exec -- cargo check --locked -p converter-core']
      }
    }
    expected.each do |file, jobs|
      jobs.each do |name, (namespace, command)|
        steps = workflow(file).fetch('jobs').fetch(name).fetch('steps')
        caches = steps.select { |step| step['uses'] == './.github/actions/rust-build-cache' }
        assert_equal 1, caches.length, "#{file}/#{name}"
        cache = caches.first
        assert_equal namespace, cache.fetch('with').fetch('namespace')
        setup = steps.index { |step| step.fetch('run', '').start_with?('mise install') }
        assert_operator setup, :<, steps.index(cache)
        validation = steps.find { |step| step.fetch('run', '').include?(command) }
        refute_nil validation
        assert_operator steps.index(cache), :<, steps.index(validation)
        refute validation.key?('if'), 'Cache hits cannot skip compilation or tests'
        refute steps.any? { |step| step.fetch('uses', '').start_with?('actions/cache@') && step.fetch('with').fetch('path', '').include?('target') }
      end
    end
  end

  def test_codeql_builds_remain_outside_the_uninstrumented_cache
    source = File.read(File.join(ROOT, '.github/workflows/codeql.yml'))
    refute_includes source, './.github/actions/rust-build-cache'
  end

  def test_audit_keeps_only_registry_downloads_and_rails_jobs_skip_the_mise_cache
    audit = workflow('rust-dependency-audit.yml').fetch('jobs').fetch('audit').fetch('steps')
    cache = audit.find { |step| step['uses'] == './.github/actions/rust-build-cache' }
    assert_equal 'false', cache.fetch('with').fetch('cache-target')
    mise = lambda do |steps|
      steps.find { |step| step.fetch('uses', '').start_with?('jdx/mise-action@') }.fetch('with')
    end
    assert_equal false, mise.call(workflow('ci.yml').fetch('jobs').fetch('rails-web').fetch('steps')).fetch('cache')
    assert_equal false, mise.call(workflow('rails-real-model.yml').fetch('jobs').values.first.fetch('steps')).fetch('cache')
  end
end
