# frozen_string_literal: true

require "json"
require "rbconfig"
require "optparse"
require_relative "tts_book_benchmark"

# Exercise superseding terminal jobs. This does not implement app seek behavior.
module TTSSeekBenchmark
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.run(manifest_path, output, cancel_after: 1.0)
    manifest = JSON.parse(File.read(manifest_path))
    TTSBookBenchmark.validate(manifest)
    raise ArgumentError, "One engine and at least four chunks are required" unless manifest.fetch("engines").length == 1 && manifest.fetch("samples").length >= 4
    raise ArgumentError, "Use a new output directory" if File.exist?(output)
    Dir.mkdir(output, 0o700)
    worker = File.join(__dir__, "tts_parallel_benchmark.rb")
    cancelled_plan = File.join(output, "old.json")
    replacement_plan = File.join(output, "new.json")
    File.write(cancelled_plan, JSON.pretty_generate(manifest.merge("samples" => manifest.fetch("samples").first(3))))
    target_samples = manifest.fetch("samples").drop(manifest.fetch("samples").length / 2).first(2)
    File.write(replacement_plan, JSON.pretty_generate(manifest.merge("samples" => target_samples)))
    command = lambda do |plan, directory|
      args = [RbConfig.ruby, worker, "--manifest", plan, "--output", directory, "--concurrency", "1", "--timeout", "90"]
      args << "--remote" if manifest.fetch("deployment") == "remote"
      args
    end
    old_output = File.join(output, "old")
    new_output = File.join(output, "new")
    pid = Process.spawn(*command.call(cancelled_plan, old_output), out: File.join(output, "old.log"), err: File.join(output, "old.stderr"), pgroup: true)
    deadline = clock + 30
    loop do
      raise "Old job did not start" if clock > deadline
      path = File.join(old_output, "report.json")
      break if File.file?(path) && !JSON.parse(File.read(path)).fetch("runs").empty?
      sleep 0.01
    end
    sleep cancel_after
    changed_at = clock
    Process.kill("INT", pid)
    status = nil
    until status
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      raise "Old job did not cancel within five seconds" if clock - changed_at > 5
      sleep 0.01 unless status
    end
    pid = nil
    cancelled_s = clock - changed_at
    old_report = JSON.parse(File.read(File.join(old_output, "report.json")))
    code, = RunSteps.execute(command.call(replacement_plan, new_output), output,
                             File.join(output, "new.log"), File.join(output, "new.stderr"), 200)
    fresh = JSON.parse(File.read(File.join(new_output, "report.json")))
    first = fresh.fetch("runs").first
    transport = first.fetch("transport", {})
    if transport["pipeline_start_monotonic_s"] && transport["complete_mp3_pipeline_s"]
      target_latency = transport.fetch("pipeline_start_monotonic_s") + transport.fetch("complete_mp3_pipeline_s") - changed_at
      latency_basis = "persisted MP3 monotonic timestamp; includes new-batch startup and validation"
    elsif transport["request_start_monotonic_s"] && transport["complete_mp3_persisted_s"]
      target_latency = transport.fetch("request_start_monotonic_s") + transport.fetch("complete_mp3_persisted_s") - changed_at
      latency_basis = "persisted MP3 monotonic timestamp; includes new-batch startup and validation"
    else
      target_latency = clock - changed_at
      latency_basis = "upper bound: entire replacement batch including decode validation"
    end
    identities_match = fresh.fetch("runs").map { |row| row.fetch("sample_sha256") } == target_samples.map { |sample| sample.fetch("sha256") }
    passed = status.exitstatus == 130 && code.zero? && identities_match && old_report.fetch("unstarted_attempts") >= 1 &&
             fresh.fetch("runs").all? { |row| row.fetch("status") == "validated" }
    report = { "status" => passed ? "passed" : "failed", "old_exit_code" => status.exitstatus,
               "cancel_and_reap_s" => cancelled_s, "old_statuses" => old_report.fetch("runs").map { |row| row.fetch("status") },
               "old_unstarted" => old_report.fetch("unstarted_attempts"), "new_exit_code" => code,
               "target_offset" => target_samples.first["offset"], "new_sample_identities_match" => identities_match,
               "seek_to_complete_target_mp3_s" => target_latency, "target_latency_basis" => latency_basis,
               "limitations" => ["Terminal process cancellation and fresh generation, not actual player seek",
                 "Old completed blocks remain isolated; no cross-job cache is used"] }
    File.write(File.join(output, "report.json"), JSON.pretty_generate(report) + "\n")
    puts JSON.generate(report)
    passed ? 0 : 1
  ensure
    if pid
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end

  def self.cli(arguments)
    options = {}
    OptionParser.new do |parser|
      parser.on("--manifest FILE") { |value| options[:manifest] = File.expand_path(value) }
      parser.on("--output DIRECTORY") { |value| options[:output] = File.expand_path(value) }
    end.parse!(arguments)
    raise ArgumentError, "Required: --manifest --output" unless arguments.empty? && options[:manifest] && options[:output]
    run(options.fetch(:manifest), options.fetch(:output))
  rescue ArgumentError, KeyError, SystemCallError, JSON::ParserError, RuntimeError => error
    warn error.message
    2
  end
end

exit TTSSeekBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
