# frozen_string_literal: true

require_relative "run_host_checks"

# Explicit fixture-only allowlist. Never discover tests: other suites build or launch apps.
module CiContracts
  RUBY_SUITES = (HostChecks::SUITES + %w[
    test_minitest_bootstrap.rb test_run_ci_contracts.rb test_ci_runtime_scope.rb test_codeql_swift_build.rb test_direct_runtime_boundary.rb
    test_bundle_onnxruntime_apple.rb
    test_package_converter_ffi_macos.rb
    test_mac_validate.rb
    test_android_jni_exports.rb
    test_device_workflow_entrypoint.rb test_native_faber_entrypoints.rb
    test_native_codex_tool_guard.rb test_native_simulator_session.rb
    test_hf_snapshot_workflow.rb test_hf_snapshot.rb
    test_download_converter_ffi_macos.rb
    test_ubuntu_package_mirror.rb
  ]).uniq.freeze
  NODE_SUITES = %w[
    .github/scripts/changelog-drift.test.cjs
    .github/scripts/dependency-audit-results.test.cjs
    .github/scripts/pr-repair-safety.test.cjs
    .github/scripts/repository-health-watchdog.test.cjs
    .github/scripts/rollback-target.test.cjs
    scripts/test_guarded_pr_merge.mjs
    scripts/test_pr_gate_policy.mjs
    scripts/test_validated_merge.mjs
    scripts/test_post_merge_validation.mjs
  ].freeze
  CONCURRENT_NODE_SUITES = %w[
    .github/scripts/dependency-audit-results.test.cjs
    .github/scripts/pr-repair-safety.test.cjs
  ].freeze
  PYTHON_SUITES = %w[
    scripts/test_android_ui_session.py
    scripts/test_capture_native_test_metadata.py
    scripts/test_simulator_resource_monitor.py
    python_app/tests/test_feature_ab_cache_isolation.py
    python_app/tests/test_feature_ab_regression.py
    python_app/tests/test_guard_ios_simulator_resources.py
    python_app/tests/test_heavy_job_guard.py
    python_app/tests/test_select_ios_simulator.py
  ].freeze
  ISOLATED_PYTHON_SUITES = %w[scripts/test_guard_remediation_changes.py].freeze

  def self.steps
    ruby = RUBY_SUITES.map { |name| { "name" => name, "argv" => HostChecks.suite_argv("scripts/#{name}") } }
    node = NODE_SUITES.filter_map do |path|
      next if path == CONCURRENT_NODE_SUITES.last
      if path == CONCURRENT_NODE_SUITES.first
        { "name" => "Independent dependency and repair contracts", "argv" => ["node", "--test", "--test-concurrency=2", *CONCURRENT_NODE_SUITES] }
      else
        { "name" => path, "argv" => ["node", "--test", path] }
      end
    end
    [{ "name" => "Git LFS prerequisite", "argv" => ["git", "lfs", "version"] }] + ruby + node + [
      { "name" => "Workflow YAML syntax", "argv" => [RbConfig.ruby, "-ryaml", "-e", 'Dir[".github/workflows/*.yml"].each { |path| YAML.parse_file(path) }'] },
      { "name" => "Actual Swift tool scope", "argv" => [RbConfig.ruby, "scripts/check_codeql_swift_tool_scope.rb"] },
      { "name" => "Shell safety syntax", "argv" => ["bash", "-n", "scripts/device-workflow.sh", ".claude/hooks/swift_test_after_edit.sh", ".claude/hooks/xcode_build_smoke.sh"] },
      { "name" => "Python offline contracts", "argv" => ["python3", "-m", "pytest", "-q", *PYTHON_SUITES], "timeout_seconds" => 180 }
    ] + ISOLATED_PYTHON_SUITES.map { |path| { "name" => path, "argv" => ["python3", "-I", path, "-v"] } }
  end

  def self.execute(root, output, selected_steps = steps)
    FileUtils.mkdir_p(File.dirname(output))
    Dir.mkdir(output, 0o700)
    plan = File.join(output, "plan.json")
    File.write(plan, JSON.pretty_generate("cwd" => root, "steps" => selected_steps) + "\n")
    RunSteps.run(plan, File.join(output, "results"))
  end

  def self.run(arguments)
    output = nil
    OptionParser.new { |parser| parser.on("--output NEW_DIRECTORY") { |path| output = File.expand_path(path) } }.parse!(arguments)
    raise ArgumentError, "Unexpected arguments" unless arguments.empty?
    root = File.expand_path("..", __dir__)
    output ||= File.join(root, ".reports", "ci-contracts", "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}")
    execute(root, output)
  rescue OptionParser::ParseError, ArgumentError, SystemCallError => error
    warn error.message
    2
  end
end

exit CiContracts.run(ARGV) if $PROGRAM_NAME == __FILE__
