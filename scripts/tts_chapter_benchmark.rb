# frozen_string_literal: true

require "json"
require "optparse"
require "rbconfig"
require_relative "tts_parallel_benchmark"

# Terminal experiments only. Playback and prefetch are trace replays, not app runs.
module TTSChapterBenchmark
  def self.chunks(text, maximum: 480, first: 180)
    raise ArgumentError, "Invalid text or chunk bounds" if text.strip.empty? || !text.valid_encoding? || first < 1 || maximum < first || maximum > 500
    result = []
    offset = 0
    while offset < text.length
      limit = result.empty? ? first : maximum
      window = text[offset, limit]
      length = window.length
      if offset + length < text.length
        # Prefer complete sentences; fall back to a word boundary for long sentences.
        sentences = window.to_enum(:scan, /[.!?][\"”’']?\s+|\n\n/).map { Regexp.last_match.end(0) }
        words = window.to_enum(:scan, /\s+/).map { Regexp.last_match.end(0) }
        length = sentences.last || words.last || length
      end
      part = text[offset, length]
      if part.strip.empty? && !result.empty?
        result.last["text"] += part
      else
        result << { "offset" => offset, "text" => part }
      end
      offset += length
    end
    raise "Chunk coverage mismatch" unless result.map { |part| part.fetch("text") }.join == text
    raise "Chunk bound exceeded" unless result.all? { |part| part.fetch("text").length <= maximum }
    result
  end

  def self.playback(rows, speed: 1.0)
    raise ArgumentError, "Invalid playback speed" unless speed.finite? && speed.positive?
    return { "status" => "incomplete" } if rows.empty? || rows.any? { |row| row["status"] != "validated" }
    ready = rows.map { |row| row.fetch("started_batch_s") + row.fetch("command_wall_s") }
    cursor = ready.first
    stalls = []
    rows.each_with_index do |row, index|
      if ready[index] > cursor
        stalls << { "index" => index, "gap_s" => ready[index] - cursor }
        cursor = ready[index]
      end
      cursor += row.fetch("audio_duration_s") / speed
    end
    { "status" => "trace_replay", "speed" => speed, "first_complete_mp3_s" => ready.first,
      "last_complete_mp3_s" => ready.max, "playback_end_s" => cursor,
      "stall_count" => stalls.length, "stall_total_s" => stalls.sum { |stall| stall.fetch("gap_s") }, "stalls" => stalls }
  end

  def self.prefetch(current, following, lead: 60.0)
    return { "status" => "incomplete" } unless current["status"] == "trace_replay" && following["status"] == "trace_replay"
    trigger = [current.fetch("first_complete_mp3_s"), current.fetch("playback_end_s") - lead].max
    { "status" => "trace_replay", "lead_s" => lead, "trigger_s" => trigger,
      "next_first_complete_mp3_s" => trigger + following.fetch("first_complete_mp3_s"),
      "predicted_boundary_gap_s" => [trigger + following.fetch("first_complete_mp3_s") - current.fetch("playback_end_s"), 0.0].max }
  end

  def self.samples(parts, prefix, source)
    parts.each_with_index.map do |part, index|
      { "id" => format("%s-%03d", prefix, index), "text" => part.fetch("text"), "offset" => part.fetch("offset"),
        "language" => "pt-BR", "source" => source, "sha256" => Digest::SHA256.hexdigest(part.fetch("text")) }
    end
  end

  def self.mp3_engine(engine, directory)
    return engine if engine.fetch("output_extension", "wav") == "mp3"
    path = File.join(directory, engine.fetch("id") + "-source-engine.json")
    File.write(path, JSON.pretty_generate(engine) + "\n")
    worker = File.join(__dir__, "tts_chapter_mp3_worker.rb")
    extra = [RbConfig.ruby, worker, File.join(__dir__, "tts_mp3_export_probe.rb"), path]
    engine.merge("output_extension" => "mp3", "argv" => [RbConfig.ruby, worker, path, "{text_file}", "{output}"],
                 "assets" => engine.fetch("assets") + extra.map { |file| { "path" => file, "sha256" => TTSBookBenchmark.sha(file) } })
  end

  def self.run(manifest_paths:, text_path:, expected_sha:, next_path:, output:)
    text = File.read(text_path)
    raise ArgumentError, "Chapter identity mismatch" unless TTSBookBenchmark.sha(text_path) == expected_sha
    raise ArgumentError, "Use a new evidence directory" if File.exist?(output)
    manifests = manifest_paths.map { |path| JSON.parse(File.read(path)) }
    manifests.each { |manifest| TTSBookBenchmark.validate(manifest) }
    engines = manifests.flat_map { |manifest| manifest.fetch("engines") }
    raise ArgumentError, "Duplicate engines" unless engines.map { |engine| engine.fetch("id") }.uniq.length == engines.length
    parts = chunks(text)
    following = chunks(File.read(next_path)).first(2)
    middle = parts.length / 2
    Dir.mkdir(output, 0o700)
    summary = { "started_utc" => Time.now.utc.iso8601, "chapter_sha256" => expected_sha,
                "chapter_characters" => text.length, "chapter_utf8_bytes" => text.bytesize,
                "next_chapter_sha256" => TTSBookBenchmark.sha(next_path), "chunks" => parts.length,
                "middle_offset" => parts.fetch(middle).fetch("offset"), "harness_sha256" => TTSBookBenchmark.sha(__FILE__),
                "limitations" => ["One run per configuration, not a statistical latency distribution",
                  "Fresh generator process per block; not a resident mobile engine",
                  "MP3 completion includes persistence; post-batch decode validation is outside generation timing",
                  "Playback/prefetch are trace replays, not speaker or application measurements",
                  "No real server throttling is intentionally provoked; stop on first refusal",
                  "Human pronunciation and mobile compatibility remain unverified"], "runs" => [] }
    checkpoint = -> { File.write(File.join(output, "summary.json"), JSON.pretty_generate(summary) + "\n") }
    checkpoint.call
    manifests.each do |manifest|
      manifest.fetch("engines").each do |original|
        engine = mp3_engine(original, output)
        remote = manifest.fetch("deployment") == "remote"
        scenarios = [["full-c1", parts, 1], ["full-c2", parts, 2], ["middle-c1", parts.drop(middle), 1], ["next-prefix-c1", following, 1]]
        scenarios.each do |name, selected, concurrency|
          id = engine.fetch("id") + "-" + name
          prepared = manifest.merge("engines" => [engine], "samples" => samples(selected, "chunk", text_path))
          prepared["samples"].each { |sample| sample["source"] = next_path } if name == "next-prefix-c1"
          plan_path = File.join(output, id + ".json")
          File.write(plan_path, JSON.pretty_generate(prepared) + "\n")
          directory = File.join(output, id)
          code = TTSParallelBenchmark.run(plan_path, directory, concurrency: concurrency, timeout: 90.0, remote: remote)
          report = JSON.parse(File.read(File.join(directory, "report.json")))
          entry = { "id" => id, "engine" => engine.fetch("id"), "scenario" => name, "concurrency" => concurrency,
                    "exit_code" => code, "generation_s" => report.fetch("generation_batch_wall_s"),
                    "with_validation_s" => report.fetch("batch_and_validation_wall_s"),
                    "expected_chunks" => selected.length, "statuses" => report.fetch("runs").group_by { |row| row.fetch("status") }.transform_values(&:length),
                    "audio_duration_s" => report.fetch("runs").sum { |row| row.fetch("audio_duration_s", 0.0) },
                    "mp3_bytes" => report.fetch("runs").sum { |row| row.fetch("audio_bytes", 0) },
                    "playback_1x" => playback(report.fetch("runs")), "playback_2x" => playback(report.fetch("runs"), speed: 2.0) }
          summary.fetch("runs") << entry
          checkpoint.call
          puts "CHAPTER #{id}: exit=#{code}; generation=#{entry.fetch('generation_s').round(2)}s"
          STDOUT.flush
          # A refusal stops the entire remote campaign; retries cannot evade it.
          if report["halt_reason"] || [130, 143].include?(code)
            summary["halt_reason"] = report["halt_reason"] || "cancelled"
            checkpoint.call
            return code.zero? ? 1 : code
          end
        end
        current = summary.fetch("runs").find { |row| row["engine"] == engine["id"] && row["scenario"] == "middle-c1" }
        next_run = summary.fetch("runs").last
        current["next_prefetch_1x"] = prefetch(current.fetch("playback_1x"), next_run.fetch("playback_1x"))
        current["next_prefetch_2x"] = prefetch(current.fetch("playback_2x"), next_run.fetch("playback_2x"))
        checkpoint.call
      end
    end
    summary["finished_utc"] = Time.now.utc.iso8601
    checkpoint.call
    summary.fetch("runs").all? { |row| row.fetch("exit_code").zero? } ? 0 : 1
  end

  def self.cli(arguments)
    options = { manifest_paths: [] }
    OptionParser.new do |parser|
      parser.on("--manifest FILE") { |value| options[:manifest_paths] << File.expand_path(value) }
      parser.on("--text FILE") { |value| options[:text_path] = File.expand_path(value) }
      parser.on("--sha256 HASH") { |value| options[:expected_sha] = value }
      parser.on("--next-text FILE") { |value| options[:next_path] = File.expand_path(value) }
      parser.on("--output DIRECTORY") { |value| options[:output] = File.expand_path(value) }
    end.parse!(arguments)
    raise ArgumentError, "Required: --manifest --text --sha256 --next-text --output" unless arguments.empty? && !options[:manifest_paths].empty? && %i[text_path expected_sha next_path output].all? { |key| options[key] }
    run(**options)
  rescue ArgumentError, KeyError, SystemCallError, JSON::ParserError => error
    warn error.message
    2
  end
end

exit TTSChapterBenchmark.cli(ARGV) if $PROGRAM_NAME == __FILE__
