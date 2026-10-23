# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "tts_book_benchmark"

# Bounded client/process concurrency. Remote server concurrency remains unknown.
module TTSParallelBenchmark
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.stop(pid)
    Process.kill("TERM", -pid)
  rescue Errno::ESRCH
    nil
  end

  def self.run(manifest_path, output, concurrency:, iterations: 1, timeout: 90, remote: false, lock_path: TTSBookBenchmark::LOCK)
    raise ArgumentError, "Concurrency must be 1..4; local maximum is 2" unless (1..(remote ? 4 : 2)).cover?(concurrency)
    raise ArgumentError, "Iterations must be 1..4" unless (1..4).cover?(iterations)
    raise ArgumentError, "Invalid deadline" unless timeout.finite? && timeout.positive?
    manifest = JSON.parse(File.read(manifest_path))
    TTSBookBenchmark.validate(manifest)
    expected_kind = remote ? "remote" : "local"
    raise ArgumentError, "Manifest deployment must match --remote" unless manifest.fetch("deployment") == expected_kind
    raise ArgumentError, "A new output directory is required" if File.exist?(output)
    raise ArgumentError, "Output extensions must be wav or mp3" unless manifest.fetch("engines").all? { |engine| %w[wav mp3].include?(engine.fetch("output_extension", "wav")) }
    lease = nil
    active = {}
    previous = {}
    cancelled = nil
    if !remote
      lease = File.open(lock_path, "a+")
      unless lease.flock(File::LOCK_EX | File::LOCK_NB)
        lease.close
        raise ArgumentError, "Another native/heavy job owns the lease"
      end
    end
    identities = manifest.fetch("engines").flat_map { |engine| engine.fetch("assets") }.to_h do |asset|
      path = asset.fetch("path")
      stat = File.stat(path)
      [path, [stat.dev, stat.ino, stat.size, stat.mtime.to_r]]
    end
    begin
      Dir.mkdir(output, 0o700)
      output = File.realpath(output)
      File.write(File.join(output, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      %w[INT TERM].each { |signal| previous[signal] = Signal.trap(signal) { cancelled ||= Signal.list.fetch(signal) } }
      pending = iterations.times.flat_map do |iteration|
        manifest.fetch("samples").flat_map do |sample|
          manifest.fetch("engines").filter_map do |engine|
            [engine, sample, iteration + 1] if engine.fetch("languages").include?(sample.fetch("language"))
          end
        end
      end
      report = { "created_utc" => Time.now.utc.iso8601, "manifest_sha256" => TTSBookBenchmark.sha(manifest_path),
                 "harness_sha256" => TTSBookBenchmark.sha(__FILE__), "concurrency" => concurrency,
                 "deployment" => expected_kind, "iterations" => iterations, "engines" => manifest.fetch("engines"),
                 "samples" => manifest.fetch("samples").map { |s| s.reject { |k, _| k == "text" } },
                 "runs" => [], "peak_active_clients" => 0,
                 "limits" => "Concurrent client processes, not measured server workers; validation runs after synthesis; same total work is required for comparisons; no automatic retries." }
      checkpoint = -> { TTSBookBenchmark.checkpoint(report, output) }
      checkpoint.call
      started = clock
      halted = nil
      while !pending.empty? || !active.empty?
        if cancelled && !halted
          halted = "cancelled"
          active.each_key { |pid| stop(pid) }
        end
        while !halted && active.length < concurrency && !pending.empty?
          engine, sample, iteration = pending.shift
          engine.fetch("assets").each do |asset|
            path = asset.fetch("path")
            stat = File.stat(path)
            raise ArgumentError, "Asset changed during batch: #{path}" unless identities.fetch(path) == [stat.dev, stat.ino, stat.size, stat.mtime.to_r]
          end
          id = "#{engine.fetch('id')}-#{sample.fetch('id')}-#{iteration}"
          input = File.join(output, sample.fetch("id") + ".txt")
          File.write(input, sample.fetch("text")) unless File.exist?(input)
          audio = File.join(output, id + "." + engine.fetch("output_extension", "wav"))
          replacements = { "{text_file}" => input, "{text}" => sample.fetch("text"), "{output}" => audio }
          argv = engine.fetch("argv").map { |arg| arg.gsub(/\{(?:text_file|text|output)\}/) { |token| replacements.fetch(token) } }
          row = { "id" => id, "engine" => engine.fetch("id"), "sample" => sample.fetch("id"), "language" => sample.fetch("language"),
                  "iteration" => iteration, "status" => "running", "argv" => argv, "audio" => audio,
                  "started_batch_s" => clock - started, "sample_sha256" => sample.fetch("sha256") }
          measured_argv = !remote && RUBY_PLATFORM.include?("darwin") ? ["/usr/bin/time", "-l", *argv] : argv
          row["measured_argv"] = measured_argv
          begin
            pid = Process.spawn([measured_argv.first, measured_argv.first], *measured_argv.drop(1), chdir: output,
                                out: File.join(output, id + ".stdout"), err: File.join(output, id + ".stderr"), pgroup: true)
            active[pid] = { row: row, started: clock }
          rescue SystemCallError => error
            row.merge!("status" => "failed", "exit_code" => 127, "error" => error.message)
          end
          report.fetch("runs") << row
          report["peak_active_clients"] = [report.fetch("peak_active_clients"), active.length].max
          checkpoint.call
          puts "START #{id}; active=#{active.length}"
          STDOUT.flush
        end
        active.keys.each do |pid|
          item = active.fetch(pid)
          row = item.fetch(:row)
          if clock - item.fetch(:started) >= timeout && !item[:stopping]
            item[:stopping] = clock
            item[:timed_out] = true
            stop(pid)
          end
          item[:stopping] ||= clock if halted
          if item[:stopping] && clock - item[:stopping] >= 1
            Process.kill("KILL", -pid) rescue Errno::ESRCH
          end
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          next unless status
          row["command_wall_s"] = clock - item.fetch(:started)
          row["exit_code"] = cancelled ? 128 + cancelled : item[:timed_out] ? 124 : status.exitstatus || 128 + status.termsig
          row["status"] = row["exit_code"].zero? ? "synthesized" : cancelled ? "cancelled" : item[:timed_out] ? "timeout" : "failed"
          stderr = File.join(output, row.fetch("id") + ".stderr")
          rss = File.read(stderr).match(/(\d+)\s+maximum resident set size/)
          row["child_peak_rss_bytes"] = rss ? Integer(rss[1]) : nil
          telemetry = audio_telemetry(row.fetch("audio"))
          row["transport"] = telemetry if telemetry
          if telemetry && ([401, 403, 429].include?(telemetry["http_status"]) || telemetry["status"] == "provider_limit_or_refusal")
            halted = "provider_limit_or_refusal"
            row["status"] = halted
            active.each_key { |other| stop(other) unless other == pid }
          end
          # A failed leader must not leave an orphaned decoder/worker running.
          Process.kill("KILL", -pid) rescue Errno::ESRCH unless row.fetch("exit_code").zero?
          active.delete(pid)
          checkpoint.call
          puts "END #{row.fetch('id')}: #{row.fetch('status')}"
          STDOUT.flush
        end
        break if halted && active.empty?
        sleep 0.01
      end
      report["generation_batch_wall_s"] = clock - started
      report["unstarted_attempts"] = pending.length
      report["halt_reason"] = halted
      # Do not replace parent signal traps while other model/HTTP clients run.
      report.fetch("runs").each do |row|
        break if cancelled
        next unless row["status"] == "synthesized"
        begin
          validated = TTSBookBenchmark.inspect_audio(row.fetch("audio"), output, 20)
          row.merge!(validated)
          if validated.fetch("validation_exit_code").zero?
            row["status"] = "validated"
            row["rtf"] = row.fetch("command_wall_s") / row.fetch("audio_duration_s")
            text = manifest.fetch("samples").find { |s| s.fetch("id") == row.fetch("sample") }.fetch("text")
            row["characters_per_s"] = text.length / row.fetch("command_wall_s")
          else
            row["status"] = "failed_validation"
            cancelled = validated.fetch("validation_exit_code") - 128 if [130, 143].include?(validated.fetch("validation_exit_code"))
          end
        rescue StandardError => error
          row.merge!("status" => "failed_validation", "error" => error.message)
        end
        checkpoint.call
      end
      report["finished_utc"] = Time.now.utc.iso8601
      report["batch_and_validation_wall_s"] = clock - started
      checkpoint.call
      return 128 + cancelled if cancelled
      report.fetch("runs").all? { |row| row["status"] == "validated" } && pending.empty? ? 0 : 1
    ensure
      active.each_key { |pid| stop(pid) }
      active.each_key do |pid|
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.waitpid(pid) rescue Errno::ECHILD
      end
      previous.each { |signal, handler| Signal.trap(signal, handler) }
      lease&.close
    end
  end

  def self.audio_telemetry(audio)
    path = audio + ".timing.json"
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  rescue JSON::ParserError
    { "telemetry_error" => "invalid JSON" }
  end

  def self.cli(arguments)
    options = { concurrency: 1, iterations: 1, timeout: 90.0, remote: false }
    manifest = nil
    output = nil
    OptionParser.new do |parser|
      parser.on("--manifest FILE") { |v| manifest = File.expand_path(v) }
      parser.on("--output DIRECTORY") { |v| output = File.expand_path(v) }
      parser.on("--concurrency N", Integer) { |v| options[:concurrency] = v }
      parser.on("--iterations N", Integer) { |v| options[:iterations] = v }
      parser.on("--timeout SECONDS", Float) { |v| options[:timeout] = v }
      parser.on("--remote") { options[:remote] = true }
    end.parse!(arguments)
    raise ArgumentError, "Required: --manifest --output" unless manifest && output && arguments.empty?
    run(manifest, output, **options)
  rescue ArgumentError, KeyError, SystemCallError, JSON::ParserError => error
    warn error.message
    2
  end
end

exit TTSParallelBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
