# frozen_string_literal: true

require_relative "run_host_checks"

# Explicit fixture-only allowlist. Never discover tests: other suites build or launch apps.
module CiContracts
  RUBY_SUITES = (HostChecks::SUITES + %w[
    test_minitest_bootstrap.rb test_run_ci_contracts.rb test_ci_runtime_scope.rb test_codeql_swift_build.rb test_direct_runtime_boundary.rb
    test_bundle_onnxruntime_apple.rb
    test_package_converter_ffi_macos.rb
    test_ios_validation_archive.rb
    test_mac_validate.rb
    test_android_jni_exports.rb
    test_device_workflow_entrypoint.rb test_native_faber_entrypoints.rb
    test_native_codex_tool_guard.rb test_native_simulator_session.rb
    test_hf_snapshot_workflow.rb test_hf_snapshot.rb
    test_download_converter_ffi_macos.rb
    test_ubuntu_package_mirror.rb test_rust_build_cache.rb test_build_web_wasm.rb
    test_runner_acquisition_retry.rb
    test_convert_entrypoint.rb
  ]).uniq.freeze
  NODE_SUITES = %w[
    .github/scripts/rust-cache-identity.test.cjs
    .github/scripts/changelog-drift.test.cjs
    .github/scripts/pr-repair-safety.test.cjs
    .github/scripts/rollback-target.test.cjs
    scripts/test_guarded_pr_merge.mjs
    scripts/test_pr_gate_policy.mjs
    scripts/test_refresh_behind_pr.mjs
    scripts/test_validated_merge.mjs
    scripts/test_post_merge_validation.mjs
  ].freeze
  PYTHON_SUITES = %w[
    scripts/test_android_ui_session.py
    scripts/test_capture_native_test_metadata.py
    scripts/test_simulator_resource_monitor.py
    scripts/test_android_target_selection.py
    scripts/test_apple_latency_evidence.py
    scripts/test_codeql_workflow.py
    scripts/test_development_run_tasks.py
    scripts/test_guard_ios_simulator_resources.py
    scripts/test_heavy_job_guard.py
    scripts/test_ios_device_mise_tasks.py
    scripts/test_ios_disk_guard.py
    scripts/test_mac_run_task.py
    scripts/test_mise_python_environment.py
    scripts/test_mobile_file_associations.py
    scripts/test_performance_evidence_gate.py
    scripts/test_performance_evidence_sources.py
    scripts/test_seed_ios_development_book.py
    scripts/test_select_ios_simulator.py
    scripts/test_sync_hf_workflow.py
    scripts/test_widget_embed_config.py
  ].freeze

  def self.steps
    ruby = RUBY_SUITES.map { |name| { "name" => name, "argv" => HostChecks.suite_argv("scripts/#{name}") } }
    node = NODE_SUITES.map { |path| { "name" => path, "argv" => ["node", "--test", path] } }
    [{ "name" => "Git LFS prerequisite", "argv" => ["git", "lfs", "version"] }] + ruby + node + [
      { "name" => "Workflow YAML syntax", "argv" => [RbConfig.ruby, "-ryaml", "-e", 'Dir[".github/workflows/*.yml"].each { |path| YAML.parse_file(path) }'] },
      { "name" => "Actual Swift tool scope", "argv" => [RbConfig.ruby, "scripts/check_codeql_swift_tool_scope.rb"] },
      { "name" => "Shell safety syntax", "argv" => ["bash", "-n", "scripts/device-workflow.sh"] },
      { "name" => "Python offline contracts", "argv" => ["python3", "-m", "pytest", "-q", *PYTHON_SUITES], "timeout_seconds" => 180 }
    ]
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
