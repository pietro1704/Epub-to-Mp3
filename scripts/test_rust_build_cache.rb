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
    assert_equal %w[~/.cargo/registry ~/.cargo/git target], options.fetch('path').split
    key = options.fetch('key')
    prefixes = options.fetch('restore-keys').lines.map(&:strip)
    [key, *prefixes].each do |entry|
      %w[runner.os runner.arch inputs.namespace steps.toolchain.outputs.identity].each do |boundary|
        assert_includes entry, "${{ #{boundary} }}"
      end
    end
    %w[Cargo.toml Cargo.lock .cargo/** mise.toml].each { |input| assert_includes key, "'#{input}'" }
    assert_includes key, "hashFiles('crates/**/*.rs', 'native/piper-runtime/**/*.rs')"
    assert_equal 2, prefixes.length
    assert key.start_with?(prefixes.first), 'Source changes must restore compatible dependency builds'
    assert prefixes.first.start_with?(prefixes.last), 'Lockfile changes may reuse dependencies within the same toolchain'
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
        'artifact-build' => ['ffi-${{ matrix.rust_target }}', 'cargo build --locked -p converter-ffi --release']
      },
      'rust-dependency-audit.yml' => {
        'audit' => ['dependency-audit', 'mise exec -- cargo check --locked -p converter-core --features kokoro-sherpa-runtime']
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
end
