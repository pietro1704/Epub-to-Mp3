# frozen_string_literal: true

require "optparse"
require "fileutils"
require "rbconfig"
require_relative "run_steps"

module HostChecks
  SUITES = %w[test_run_steps.rb test_scoped_git_index.rb test_native_build_preflight.rb test_mac_build_budget.rb test_xcode_build_paths.rb
              test_native_job.rb test_native_task_wiring.rb test_native_hook_safety.rb test_native_entrypoint_safety.rb test_update_instruction.rb
              test_git_hygiene.rb test_run_host_checks.rb test_xcresult_job.rb
              test_agent_collaboration.mjs test_install_agent_collaboration.mjs
              test_collaboration_doctor.mjs test_revalidate_collaboration.mjs].freeze

  def self.suite_argv(path)
    case File.extname(path)
    when ".rb" then [RbConfig.ruby, path]
    when ".mjs" then ["node", "--test", path]
    else raise ArgumentError, "Unsupported host suite: #{path}"
    end
  end

  def self.run(arguments)
    suites = []
    output = nil
    parser = OptionParser.new do |options|
      options.banner = "Usage: run_host_checks.rb [--suite FILE] [--output NEW_DIRECTORY]"
      options.on("--suite FILE") { |path| suites << File.expand_path(path) }
      options.on("--output NEW_DIRECTORY") { |path| output = File.expand_path(path) }
    end
    parser.parse!(arguments)
    raise ArgumentError, "Unexpected arguments" unless arguments.empty?
    root = File.expand_path("..", __dir__)
    suites = SUITES.map { |name| File.join(__dir__, name) } if suites.empty?
    raise ArgumentError, "Every selected suite must exist" unless suites.all? { |path| File.file?(path) }
    unless output
      parent = File.join(root, ".reports", "host-workflow")
      FileUtils.mkdir_p(parent)
      output = File.join(parent, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}")
    end
    # The plan is retained alongside logs, so each result can be reproduced.
    plan = { "cwd" => root, "steps" => suites.map { |path| { "name" => File.basename(path), "argv" => suite_argv(path) } } }
    Dir.mkdir(output, 0o700)
    plan_path = File.join(output, "plan.json")
    File.write(plan_path, JSON.pretty_generate(plan) + "\n")
    puts "Host workflow evidence: #{output}"
    RunSteps.run(plan_path, File.join(output, "results"))
  rescue OptionParser::ParseError, ArgumentError, SystemCallError => error
    warn error.message
    2
  end
end

exit HostChecks.run(ARGV) if $PROGRAM_NAME == __FILE__
