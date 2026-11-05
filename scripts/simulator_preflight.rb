# frozen_string_literal: true

require "optparse"
require "time"
require_relative "simulator_resources"
require_relative "native_job"

module SimulatorPreflight
  def self.run(report:, seconds: 60, interval: 5, sampler: nil, lock: NativeJob::LOCK_PATH)
    raise SimulatorResources::Refusal, "Report already exists" if File.exist?(report)
    evidence = { "started_at" => Time.now.utc.iso8601, "samples" => [], "admitted" => false }
    sampler ||= -> { SimulatorResources.snapshot(root: MacBuildBudget::ROOT) }
    lease, inherited = NativeJob.lease(lock)
    raise SimulatorResources::Refusal, "Standalone preflight cannot inherit a native job" if inherited
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    initial = nil
    loop do
      sampled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sample = sampler.call
      initial ||= sample
      evidence["samples"] << sample.merge("elapsed_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
      error = SimulatorResources.admission(sample, initial)
      evidence["refusal"] ||= error if error
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start >= seconds
      sleep [interval - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - sampled_at), 0].max
    end
    evidence["admitted"] = !evidence.key?("refusal")
    evidence
  rescue StandardError => error
    evidence ||= { "samples" => [], "admitted" => false }
    evidence["refusal"] = error.message
    evidence
  ensure
    lease&.close unless inherited
    if evidence && !File.exist?(report)
      File.open(report, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(evidence.merge("finished_at" => Time.now.utc.iso8601)))
      end
    end
  end

  def self.main(arguments)
    options = {}
    OptionParser.new { |parser| parser.on("--report PATH") { |path| options[:report] = path } }.parse!(arguments)
    raise "Usage: simulator_preflight.rb --report NEW_FILE" unless options[:report] && arguments.empty?
    raise "Resource preflight requires macOS" unless RUBY_PLATFORM.include?("darwin")
    result = run(**options)
    puts JSON.pretty_generate(result)
    result["admitted"] ? 0 : 75
  rescue StandardError => error
    warn error.message
    75
  end
end

exit SimulatorPreflight.main(ARGV) if $PROGRAM_NAME == __FILE__
