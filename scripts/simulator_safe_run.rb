# frozen_string_literal: true

require "optparse"
require_relative "simulator_session"
require_relative "simulator_backend"

module SimulatorSafeRun
  def self.main(arguments, backend_class: SimulatorBackend, launcher: SimulatorSession.method(:launch))
    options = {}
    parser = OptionParser.new do |p|
      p.on("--device UUID") { |v| options[:device] = v }
      p.on("--app PATH") { |v| options[:app] = v }
      p.on("--report-directory PATH") { |v| options[:directory] = v }
      p.on("--acknowledge-intel-panic-risk") { options[:acknowledged] = true }
    end
    parser.parse!(arguments)
    unless arguments.empty? && options.values_at(:device, :app, :directory, :acknowledged).all?
      raise "Requires --device, --app, --report-directory and --acknowledge-intel-panic-risk"
    end
    Dir.mkdir(options[:directory], 0o700)
    directory = File.realpath(options[:directory])
    backend = backend_class.new(device: options[:device], app: options[:app], directory: directory)
    launcher.call(backend: backend, sampler: -> { SimulatorResources.snapshot(root: MacBuildBudget::ROOT) },
                  report: File.join(directory, "report.json"))
  rescue StandardError => error
    warn error.message
    75
  end
end

exit SimulatorSafeRun.main(ARGV) if $PROGRAM_NAME == __FILE__
