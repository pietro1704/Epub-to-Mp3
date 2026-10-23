#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "csv"
require "digest"
require "optparse"
require "rbconfig"
require "erb"
require_relative "run_steps"

# Experimental terminal tooling. Commands are literal argv; no app preferences,
# downloads, shell expansion, audio playback, or compilation are performed.
module TTSBookBenchmark
  LOCK = "/tmp/epub2mp3.heavy-job.lock"
  ID = /\A[a-zA-Z0-9_-]+\z/

  def self.sha(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.verify_assets(assets)
    raise ArgumentError, "assets must be a nonempty array" unless assets.is_a?(Array) && !assets.empty?
    assets.each do |asset|
      path = asset.fetch("path")
      expected = asset.fetch("sha256")
      raise ArgumentError, "Asset identity mismatch: #{path}" unless File.file?(path) && sha(path) == expected
    end
  end

  def self.validate(manifest)
    samples = manifest.fetch("samples")
    engines = manifest.fetch("engines")
    raise ArgumentError, "Samples and engines must be nonempty" if samples.empty? || engines.empty?
    [samples, engines].each do |items|
      ids = items.map { |item| item.fetch("id") }
      raise ArgumentError, "Invalid or duplicate identity" unless ids.uniq == ids && ids.all? { |id| id.is_a?(String) && ID.match?(id) }
    end
    samples.each do |sample|
      text = sample.fetch("text")
      raise ArgumentError, "Empty or modified sample" unless text.is_a?(String) && !text.strip.empty? && Digest::SHA256.hexdigest(text) == sample.fetch("sha256")
      sample.fetch("language")
      sample.fetch("source")
    end
    engines.each do |engine|
      engine.fetch("model")
      engine.fetch("voice")
      engine.fetch("languages")
      argv = engine.fetch("argv")
      valid = argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.include?("\0") }
      raise ArgumentError, "Invalid argv" unless valid && argv.any? { |arg| arg.include?("{output}") }
      raise ArgumentError, "Executable must be absolute" unless argv.first.start_with?("/") && File.executable?(argv.first)
      verify_assets(engine.fetch("assets"))
      executable = engine.fetch("assets").any? { |asset| File.realpath(asset.fetch("path")) == File.realpath(argv.first) }
      raise ArgumentError, "Executable identity is missing" unless executable
      raise ArgumentError, "Engine has no matching samples" unless samples.any? { |s| engine.fetch("languages").include?(s.fetch("language")) }
    end
    identities = engines.flat_map do |engine|
      samples.filter_map { |sample| "#{engine.fetch('id')}-#{sample.fetch('id')}" if engine.fetch("languages").include?(sample.fetch("language")) }
    end
    raise ArgumentError, "Derived attempt identities collide" unless identities.uniq.length == identities.length
    manifest.fetch("books", []).each do |book|
      raise ArgumentError, "Book identity mismatch" unless sha(book.fetch("path")) == book.fetch("sha256")
    end
  end

  def self.command(argv, directory, prefix, timeout)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, = RunSteps.execute(argv, directory, prefix + ".stdout", prefix + ".stderr", timeout)
    [code, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def self.inspect_audio(path, directory, timeout)
    raise ArgumentError, "Output is missing or unsafe" unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?(File.realpath(directory) + "/")
    code, = command(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path], directory, path + ".probe", timeout)
    return { "validation_exit_code" => code } unless code.zero?
    duration = Float(JSON.parse(File.read(path + ".probe.stdout")).fetch("format").fetch("duration"))
    raise ArgumentError, "Invalid duration" unless duration.finite? && duration.positive?
    code, = command(["ffmpeg", "-nostdin", "-xerror", "-v", "info", "-i", path, "-af", "volumedetect", "-f", "null", "-"], directory, path + ".decode", timeout)
    return { "validation_exit_code" => code } unless code.zero?
    peak = File.read(path + ".decode.stderr").match(/max_volume:\s+(-?[\d.]+) dB/)
    raise ArgumentError, "Output is silent or below -60 dB" unless peak && Float(peak[1]) > -60
    { "validation_exit_code" => 0, "audio_duration_s" => duration, "peak_db" => Float(peak[1]), "audio_sha256" => sha(path), "audio_bytes" => File.size(path) }
  end

  def self.checkpoint(report, directory)
    path = File.join(directory, "report.json")
    File.write(path + ".partial", JSON.pretty_generate(report) + "\n")
    File.rename(path + ".partial", path)
    keys = %w[id engine sample language iteration status exit_code command_wall_s audio_duration_s rtf characters_per_s audio_sha256]
    CSV.open(File.join(directory, "results.csv"), "w") do |csv|
      csv << keys
      report.fetch("runs").each { |row| csv << keys.map { |key| row[key] } }
    end
    publish_report(report, directory)
  end

  def self.publish_report(report, directory)
    escape = ->(value) { ERB::Util.html_escape(value.to_s) }
    rows = report.fetch("runs")
    expected = report.fetch("iterations") * report.fetch("samples").sum do |sample|
      report.fetch("engines").count { |engine| engine.fetch("languages").include?(sample.fetch("language")) }
    end
    state = report.key?("finished_utc") ? "Finished" : "In progress / incomplete"
    counts = rows.group_by { |row| row.fetch("status") }.transform_values(&:length)
    median = lambda do |values|
      sorted = values.compact.sort
      sorted.empty? ? "pending" : ((sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2.0).round(3)
    end
    aggregates = rows.group_by { |row| [row.fetch("engine"), row.fetch("sample")] }.map do |(engine, sample), attempts|
      valid = attempts.select { |row| row.fetch("status") == "validated" }
      values = [engine, sample, "#{valid.length}/#{attempts.length}", median.call(valid.map { |r| r["command_wall_s"] }), median.call(valid.map { |r| r["rtf"] }), median.call(valid.map { |r| r["child_peak_rss_bytes"]&.fdiv(1_048_576) })]
      "<tr>" + values.map { |value| "<td>#{escape.call(value)}</td>" }.join + "</tr>"
    end.join("\n")
    table = rows.map do |row|
      audio = row["status"] == "validated" ? "<audio controls preload='none' src='#{escape.call(File.basename(row.fetch('audio')))}'></audio>" : ""
      cells = %w[engine sample iteration status command_wall_s audio_duration_s rtf child_peak_rss_bytes].map do |key|
        value = row[key]
        value = value.round(3) if value.is_a?(Float)
        "<td>#{escape.call(value)}</td>"
      end.join
      "<tr>#{cells}<td>#{audio}</td></tr>"
    end.join("\n")
    summary = "#{state}; #{rows.count { |row| row['status'] != 'running' }}/#{expected} terminal attempts; #{counts}"
    html = <<~HTML
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Book TTS benchmark</title><style>body{font:16px system-ui;margin:24px;background:#fafafa;color:#18202b}table{border-collapse:collapse;width:100%}th,td{padding:8px;border-bottom:1px solid #ccd;text-align:left}audio{width:230px}main{overflow-x:auto}p{max-width:1000px}.warning{background:#fff0c2;padding:12px}</style>
      <h1>Book TTS benchmark</h1><p>#{escape.call(summary)}</p>
      <p class="warning">Human listening quality: pending. Intel desktop CPU results do not prove iOS 15 or older Android compatibility. Refresh this file for incremental results.</p>
      <p>Timing is fresh-process command to complete audio, including loading. RTF = synthesis wall time / original audio duration; lower is faster. RSS is child-process peak bytes, excluding speech helper services. Model weights/quantization/backends are distinct configurations. Streaming first audio and warm loaded-model latency are unmeasured.</p>
      <h2>Successful-attempt medians</h2><p>Fractions count validated / started attempts. Partial medians are conditional on success; failures remain visible below.</p>
      <main><table><thead><tr><th>Configuration</th><th>Text</th><th>Validated/started</th><th>Wall s</th><th>RTF</th><th>Child RSS MiB</th></tr></thead><tbody>#{aggregates}</tbody></table></main>
      <h2>Attempts and audio</h2>
      <main><table><thead><tr><th>Configuration</th><th>Text</th><th>Repeat</th><th>Status</th><th>Wall s</th><th>Audio s</th><th>RTF</th><th>Child RSS bytes</th><th>Original audio</th></tr></thead><tbody>#{table}</tbody></table></main>
      <p>Assess accent, naturalness, pacing, pronunciation, missing text and repetitions. Full decoding and non-silence alone do not establish those qualities. Original audio is preserved; silence reduction is deferred.</p>
      <p><a href="report.json">Raw JSON and provenance</a> · <a href="results.csv">CSV</a> · <a href="results.md">Markdown summary</a></p></html>
    HTML
    File.write(File.join(directory, "index.html.partial"), html)
    File.rename(File.join(directory, "index.html.partial"), File.join(directory, "index.html"))
    markdown = "# Book TTS benchmark results\n\n#{summary}\n\nUpdated: #{Time.now.utc.iso8601}.\n\n[Interactive report](index.html) | [Raw evidence](report.json) | [CSV](results.csv)\n\n"
    markdown += "Human quality evaluation, warm loaded-model measurements and old-phone runtime acceptance remain pending. Originals are preserved; silence reduction is deferred.\n\n"
    markdown += "| Configuration | Text | Repeat | Status | Wall s | Audio s | RTF |\n| --- | --- | ---: | --- | ---: | ---: | ---: |\n"
    rows.each do |row|
      markdown += "| " + %w[engine sample iteration status command_wall_s audio_duration_s rtf].map { |key| row[key].is_a?(Float) ? row[key].round(3) : row[key] }.join(" | ") + " |\n"
    end
    File.write(File.join(directory, "results.md.partial"), markdown)
    File.rename(File.join(directory, "results.md.partial"), File.join(directory, "results.md"))
  end

  def self.run(manifest_path, directory, iterations: 3, timeout: 120, execute: false, lock_path: LOCK)
    raise ArgumentError, "Iterations must be 1..10" unless (1..10).cover?(iterations)
    raise ArgumentError, "Timeout must be positive and finite" unless timeout.finite? && timeout.positive?
    manifest = JSON.parse(File.read(manifest_path))
    validate(manifest)
    plan = { "manifest_sha256" => sha(manifest_path), "iterations" => iterations, "timeout_s" => timeout, "engines" => manifest.fetch("engines"), "samples" => manifest.fetch("samples").map { |s| s.reject { |k, _| k == "text" } } }
    unless execute
      preview = plan.merge("engines" => plan.fetch("engines").map do |engine|
        engine.reject { |key, _| key == "assets" }.merge("verified_asset_files" => engine.fetch("assets").length)
      end)
      puts JSON.pretty_generate(preview)
      return 0
    end
    raise ArgumentError, "A new output directory is required" unless directory && !File.exist?(directory)
    lease = File.open(lock_path, "a+")
    begin
      raise ArgumentError, "Another native/heavy job is active" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
      Dir.mkdir(directory, 0o700)
      directory = File.realpath(directory)
      report = plan.merge("started_utc" => Time.now.utc.iso8601, "harness_sha256" => sha(__FILE__), "supervisor_sha256" => sha(File.join(__dir__, "run_steps.rb")), "host" => RbConfig::CONFIG.values_at("host_cpu", "host_os"), "process_state" => "fresh_process; filesystem and OS caches not purged", "limitations" => ["No streaming/first-audible or warm loaded-model timing", "No total service memory, mobile, energy or subjective quality measurement", "Full decoding and non-silence do not prove text fidelity"], "runs" => [])
      File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      checkpoint(report, directory)
      iterations.times do |iteration|
        manifest.fetch("samples").each_with_index do |sample, index|
          text_file = File.join(directory, sample.fetch("id") + ".txt")
          File.write(text_file, sample.fetch("text"))
          engines = manifest.fetch("engines")
          engines = engines.reverse if (iteration + index).odd?
          engines.each do |engine|
            next unless engine.fetch("languages").include?(sample.fetch("language"))
            verify_assets(engine.fetch("assets"))
            id = "#{engine.fetch('id')}-#{sample.fetch('id')}-#{iteration + 1}"
            audio = File.join(directory, id + ".wav")
            substitutions = { "{text_file}" => text_file, "{text}" => sample.fetch("text"), "{output}" => audio }
            argv = engine.fetch("argv").map { |arg| arg.gsub(/\{(?:text_file|text|output)\}/) { |token| substitutions.fetch(token) } }
            row = { "id" => id, "engine" => engine.fetch("id"), "sample" => sample.fetch("id"), "language" => sample.fetch("language"), "iteration" => iteration + 1, "argv" => argv, "status" => "running", "audio" => audio, "model" => engine.fetch("model"), "voice" => engine.fetch("voice"), "sample_sha256" => sample.fetch("sha256") }
            report.fetch("runs") << row
            checkpoint(report, directory)
            puts "START #{id}"
            STDOUT.flush
            measured_argv = RbConfig::CONFIG.fetch("host_os").include?("darwin") ? ["/usr/bin/time", "-l", *argv] : argv
            row["measured_argv"] = measured_argv
            code, elapsed = command(measured_argv, directory, File.join(directory, id), timeout)
            row.merge!("exit_code" => code, "command_wall_s" => elapsed)
            rss = File.read(File.join(directory, id) + ".stderr").match(/(\d+)\s+maximum resident set size/)
            row["child_peak_rss_bytes"] = rss ? Integer(rss[1]) : nil
            if code.zero?
              begin
                row.merge!(inspect_audio(audio, directory, timeout))
                code = row.fetch("validation_exit_code")
                row["exit_code"] = code
                if code.zero?
                  row["rtf"] = elapsed / row.fetch("audio_duration_s")
                  row["characters_per_s"] = sample.fetch("text").length / elapsed
                end
              rescue StandardError => error
                row.merge!("exit_code" => 1, "error" => error.message)
                code = 1
              end
            end
            row["status"] = code.zero? ? "validated" : code == 124 ? "timeout" : [130, 143].include?(code) ? "cancelled" : "failed"
            checkpoint(report, directory)
            puts "END #{id}: #{row.fetch('status')} (#{elapsed.round(3)} s)"
            return code if [130, 143].include?(code)
          end
        end
      end
      report["finished_utc"] = Time.now.utc.iso8601
      checkpoint(report, directory)
      report.fetch("runs").all? { |row| row.fetch("status") == "validated" } ? 0 : 1
    ensure
      lease.close
    end
  end

  def self.cli(arguments)
    options = { iterations: 3, timeout: 120.0, execute: false }
    parser = OptionParser.new do |p|
      p.banner = "Usage: tts_book_benchmark.rb --manifest FILE [--run --output NEW_DIRECTORY]"
      p.on("--manifest FILE") { |v| options[:manifest] = File.expand_path(v) }
      p.on("--output DIRECTORY") { |v| options[:output] = File.expand_path(v) }
      p.on("--iterations N", Integer) { |v| options[:iterations] = v }
      p.on("--timeout SECONDS", Float) { |v| options[:timeout] = v }
      p.on("--run") { options[:execute] = true }
      p.on("--dry-run") { options[:execute] = false }
      p.on("-h", "--help") { puts p; return 0 }
    end
    parser.parse!(arguments)
    raise ArgumentError, "--manifest is required; unexpected positional arguments" unless options[:manifest] && arguments.empty?
    run(options[:manifest], options[:output], iterations: options[:iterations], timeout: options[:timeout], execute: options[:execute])
  rescue ArgumentError, KeyError, JSON::ParserError, SystemCallError => error
    warn error.message
    2
  end
end

exit TTSBookBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
