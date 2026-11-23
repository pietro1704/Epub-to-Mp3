# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Checks that used to fail only after the merge now run on the pull request when
# the change touches their area, and are not run twice in the integrated run.
class CiPrCoverageTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  INTEGRATED = "inputs.full_validation == true && github.ref == 'refs/heads/master' && contains(github.workflow_ref, '/.github/workflows/post-merge-validation.yml@')"

  def workflow(name) = YAML.load_file(File.join(ROOT, '.github/workflows', name))

  def test_ci_calls_the_post_merge_workflows_on_their_scopes_and_skips_them_when_integrated
    jobs = workflow('ci.yml').fetch('jobs')
    { 'jni-contracts' => ['rust', 'faber-jni-contracts.yml'], 'rails-browser' => ['rails', 'rails-real-model.yml'],
      'rust-audit' => ['lockfile', 'rust-dependency-audit.yml'] }.each do |name, (scope, file)|
      job = jobs.fetch(name)
      assert_equal "needs.changes.outputs.#{scope} == 'true' && !(#{INTEGRATED})", job.fetch('if'), name
      assert_equal "./.github/workflows/#{file}", job.fetch('uses'), name
      assert_equal({ 'contents' => 'read' }, job.fetch('permissions'), name)
      assert_includes jobs.fetch('pr-gate').fetch('needs'), name
    end
    post = workflow('post-merge-validation.yml').fetch('jobs')
    assert_equal './.github/workflows/rails-real-model.yml', post.fetch('browser').fetch('uses')
    assert_equal './.github/workflows/rust-dependency-audit.yml', post.fetch('audit').fetch('uses')
  end

  def test_jni_contracts_live_in_one_reusable_workflow_used_by_faber_and_ci
    jni = workflow('faber-jni-contracts.yml')
    events = jni.fetch('on', jni[true])
    assert events.key?('workflow_call') && events.key?('workflow_dispatch')
    commands = jni.fetch('jobs').fetch('contracts').fetch('steps').filter_map { |step| step['run'] }.join("\n")
    %w[test_bundle_onnxruntime_apple.rb test_verify_android_piper_inference.rb typed_preferences controlled_typed_options
       queued_streaming_ opaque_tts_policy_state --features\ android-jni].each { |part| assert_includes commands, part }
    faber = workflow('faber-integration.yml').fetch('jobs').fetch('ffi-jni')
    assert_equal './.github/workflows/faber-jni-contracts.yml', faber.fetch('uses')
    assert_includes faber.fetch('if'), 'inputs.macos_only != true'
  end

  def test_native_host_tests_run_in_the_apple_gate_with_the_commands_of_the_old_job
    old = workflow('native-hook-safety.yml').fetch('jobs').values.first.fetch('steps').filter_map { |step| step['run'] }
    gate = workflow('faber-integration.yml').fetch('jobs').fetch('macos-preferences').fetch('steps')
    host = gate.select { |step| step['if'].to_s.include?('inputs.native_host_tests == true') }
    refute_empty host
    host.each { |step| assert_includes step.fetch('if'), "matrix.arch == 'arm64'" }
    commands = host.map { |step| step['run'] }.join("\n")
    old.reject { |command| command.start_with?('mise install') }.each do |command|
      command.lines.map(&:strip).reject(&:empty?).each { |line| assert_includes commands, line.sub(/ --jobs 1\z/, '') }
    end
    faber = workflow('faber-integration.yml')
    inputs = (faber['on'] || faber[true]).fetch('workflow_call').fetch('inputs')
    assert_equal false, inputs.fetch('native_host_tests').fetch('default')
  end

  def test_dependency_audit_installs_a_checksum_pinned_binary_instead_of_compiling_the_auditor
    text = File.read(File.join(ROOT, '.github/workflows/rust-dependency-audit.yml'))
    refute_includes text, 'cargo install'
    assert_includes text, 'sha256=7fb9497f8594b389e5fce5ef9b92db08432996895b2e0c5a0167a69ed445c428'
    assert_includes text, 'cargo-audit-x86_64-unknown-linux-musl-v$version.tgz'
    assert_includes text, 'sha256sum --check --status'
    assert_includes text, 'mise exec -- cargo audit --json'
  end
end
