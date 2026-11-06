# frozen_string_literal: true

require "optparse"
require_relative "simulator_session"
require_relative "simulator_backend"
require_relative "simulator_test_backend"

module SimulatorSafeRun
  def self.main(arguments, backend_class: SimulatorBackend, launcher: SimulatorSession.method(:launch))
    options = {}
    parser = OptionParser.new do |p|
      p.on("--device UUID") { |v| options[:device] = v }
      p.on("--app PATH") { |v| options[:app] = v }
      p.on("--report-directory PATH") { |v| options[:directory] = v }
      p.on("--acknowledge-intel-panic-risk") { options[:acknowledged] = true }
      p.on("--allow-stable-existing-swap") { options[:stable_existing_swap] = true }
      p.on("--observe-resources") { options[:observe_resources] = true }
      p.on("--test-run PATH") { |v| options[:test_run] = v }
      p.on("--test-selector METHOD") { |v| options[:test_selector] = v }
      p.on("--test-manifest JSON") { |v| options[:test_manifest] = v }
      p.on("--seed-book EPUB") { |v| options[:seed_book] = v }
    end
    parser.parse!(arguments)
    unless arguments.empty? && options.values_at(:device, :app, :directory, :acknowledged).all?
      raise "Requires --device, --app, --report-directory and --acknowledge-intel-panic-risk"
    end
    raise "Observation and stable-swap modes are mutually exclusive" if options[:observe_resources] && options[:stable_existing_swap]
    if options[:test_run] || options[:test_selector] || options[:test_manifest]
      raise "Tests require observation mode, a test run and selector or manifest" unless options[:observe_resources] && options[:test_run] && [options[:test_selector], options[:test_manifest]].compact.length == 1
    end
    raise "Seed book requires a test run" if options[:seed_book] && !options[:test_run]
    Dir.mkdir(options[:directory], 0o700)
    directory = File.realpath(options[:directory])
    identity = { device: options[:device], app: options[:app], directory: directory }
    backend = if options[:test_run]
                SimulatorTestBackend.new(**identity, test_run: options[:test_run], test_selector: options[:test_selector], test_manifest: options[:test_manifest], seed_book: options[:seed_book])
              else
                backend_class.new(**identity)
              end
    timing = options[:observe_resources] ? { observe_resources: true, baseline_seconds: 5, session_seconds: 180 } : {}
    launcher.call(backend: backend, sampler: -> { SimulatorResources.snapshot(root: MacBuildBudget::ROOT) },
                  report: File.join(directory, "report.json"), stable_existing_swap: options[:stable_existing_swap] == true, **timing)
  rescue StandardError => error
    warn error.message
    75
  end
end

exit SimulatorSafeRun.main(ARGV) if $PROGRAM_NAME == __FILE__
