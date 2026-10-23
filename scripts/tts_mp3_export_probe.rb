# frozen_string_literal: true

require "json"
require "digest"
require "optparse"

# Compose generation, encoding and durable local persistence as one timed job.
module TTSMP3ExportProbe
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.run(argv:, generated:, output:, source_format:)
    valid = argv.is_a?(Array) && !argv.empty? && argv.all? { |v| v.is_a?(String) && !v.include?("\0") }
    raise ArgumentError, "Use literal argv and a reviewed source format" unless valid && %w[wav mp3].include?(source_format)
    raise ArgumentError, "Never overwrite an earlier export" if [generated, output, output + ".partial", output + ".timing.json"].any? { |p| File.exist?(p) }
    started = clock
    report = { "pipeline_start_monotonic_s" => started, "export_format" => "MP3 mono 24000Hz 48kbps",
               "export_probe_sha256" => Digest::SHA256.file(__FILE__).hexdigest, "generator_argv" => argv,
               "generation_source_format" => source_format, "status" => "started" }
    code = 0
    child = nil
    begin
      # Descendants stay in the supervisor-owned process group for cancellation.
      child = Process.spawn([argv.first, argv.first], *argv.drop(1), out: output + ".generate.stdout", err: output + ".generate.stderr")
      _, status = Process.waitpid2(child)
      child = nil
      code = status.exitstatus || 128 + status.termsig
      report["generator_exit_code"] = code
      report["generated_file_available_s"] = clock - started
      telemetry_path = generated + ".timing.json"
      if File.file?(telemetry_path)
        transport = JSON.parse(File.read(telemetry_path))
        report.merge!(transport)
        report["worker_transport"] = transport
        if transport["request_start_monotonic_s"]
          offset = transport.fetch("request_start_monotonic_s") - started
          %w[first_pcm_request_s first_non_silent_pcm_request_s].each do |key|
            report[key.sub("request", "pipeline")] = offset + transport[key] if transport[key]
          end
        end
      end
      if code.zero?
        raise "Generator returned no regular audio file" unless File.file?(generated) && !File.symlink?(generated)
        encode_started = clock
        if source_format == "mp3"
          File.open(output + ".partial", "wb", 0o600) do |file|
            IO.copy_stream(generated, file)
            file.flush
            file.fsync
          end
          File.rename(output + ".partial", output)
          report["encoding"] = "original MP3 copied without lossy re-encoding"
        else
          args = ["ffmpeg", "-nostdin", "-v", "error", "-i", generated, "-ac", "1", "-ar", "24000", "-c:a", "libmp3lame", "-b:a", "48k", "-threads", "1", "-f", "mp3", output + ".partial"]
          child = Process.spawn(*args, out: output + ".encode.stdout", err: output + ".encode.stderr")
          _, encoded = Process.waitpid2(child)
          child = nil
          raise "MP3 encoder failed with #{encoded.exitstatus}" unless encoded.success?
          File.open(output + ".partial", "r+") { |file| file.fsync }
          File.rename(output + ".partial", output)
          report["encoding"] = "WAV -> libmp3lame MP3; one encoder thread"
        end
        report["encode_and_persist_s"] = clock - encode_started
        report["complete_mp3_pipeline_s"] = clock - started
        report["mp3_sha256"] = Digest::SHA256.file(output).hexdigest
        report["mp3_bytes"] = File.size(output)
        report["status"] = "exported_mp3_needs_decode_validation"
      else
        report["status"] = "generator_failed" if report["status"] == "started"
      end
    rescue Interrupt
      report["status"] = "cancelled"
      code = 130
    rescue StandardError => error
      report.merge!("status" => "export_failed", "error" => "#{error.class}: #{error.message}")
      code = 1
    ensure
      if child
        Process.kill("TERM", child) rescue Errno::ESRCH
        Process.kill("KILL", child) rescue Errno::ESRCH
        Process.waitpid(child) rescue Errno::ECHILD
      end
      report["export_total_s"] = clock - started
      File.write(output + ".timing.json.partial", JSON.pretty_generate(report) + "\n")
      File.rename(output + ".timing.json.partial", output + ".timing.json")
    end
    puts JSON.generate(report)
    code
  end

  def self.cli(arguments)
    options = {}
    OptionParser.new do |parser|
      parser.on("--argv-json JSON") { |v| options[:argv] = JSON.parse(v) }
      parser.on("--generated FILE") { |v| options[:generated] = File.expand_path(v) }
      parser.on("--output FILE") { |v| options[:output] = File.expand_path(v) }
      parser.on("--source-format FORMAT") { |v| options[:source_format] = v }
    end.parse!(arguments)
    raise ArgumentError, "Required: --argv-json --generated --output --source-format" unless arguments.empty? && %i[argv generated output source_format].all? { |key| options[key] }
    run(**options)
  rescue ArgumentError, JSON::ParserError, SystemCallError => error
    warn error.message
    2
  end
end

exit TTSMP3ExportProbe.cli(ARGV) if $PROGRAM_NAME == __FILE__
