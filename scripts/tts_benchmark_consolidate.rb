# frozen_string_literal: true

require "json"
require "erb"
require "time"
require "pathname"
require_relative "tts_chapter_benchmark"

# Aggregate evidence without publishing book text, model files or local paths.
module TTSBenchmarkConsolidate
  def self.read(path)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  end

  def self.number(value)
    value.is_a?(Numeric) ? format("%.2f", value) : "pending"
  end

  def self.median(values)
    sorted = values.compact.sort
    return nil if sorted.empty?
    middle = sorted.length / 2
    sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def self.buffer_replay(rows, speed:, blocks:)
    return { "status" => "incomplete" } if rows.empty? || rows.any? { |row| row["status"] != "validated" }
    raise ArgumentError, "Invalid startup block count" unless blocks.is_a?(Integer) && blocks.positive? && blocks <= rows.length
    ready = rows.first(blocks).map { |row| row.fetch("started_batch_s") + row.fetch("command_wall_s") }.max
    delayed = rows.map(&:dup)
    delayed.first["command_wall_s"] = ready - delayed.first.fetch("started_batch_s")
    result = TTSChapterBenchmark.playback(delayed, speed: speed)
    result["first_playback_s"] = result.delete("first_complete_mp3_s")
    result["startup_blocks"] = blocks
    result
  end

  def self.sections(root)
    sections = []
    paragraph = ->(text) { sections << { text: text } }
    heading = ->(text) { sections << { heading: text } }
    table = ->(headers, rows) { sections << { headers: headers, rows: rows } }
    paragraph.call("Measured on an Intel Mac, 2026-10-23. Terminal research only; no application integration or default change. No paid inference used. Filesystem/OS caches were not purged; remote model revisions and server-side caching are not exposed. Human pronunciation/naturalness and iOS 15/older Android runtime acceptance remain pending.")
    heading.call("Recommendation and consistent client policy")
    table.call(["Role", "Candidate", "Reason and limit"], [
      ["Primary offline", "Piper Faber PT-BR / Lessac EN", "Portable candidate with competitive measured speed; mobile runtime and voice quality still require acceptance."],
      ["Automatic local fallback", "Installed system voice", "Prefer Luciana on Apple PT-BR when installed; platform voices differ. Browser native speech is listening-only."],
      ["Optional online", "Edge Francisca PT-BR / Guy EN", "Explicit consent; service limits and the observed long-job timeout require bounded jobs and recovery. The tested Edge client is local software using remote inference; it is not an offline model."],
      ["Further candidate", "Pocket INT8", "Retain for listening and resident/mobile-engine evaluation; not established as a better PT-BR default."]])
    heading.call("Initial offline comparison")
    offline = read(File.join(root, "evidence/run-01/report.json"))
    if offline
      rows = offline.fetch("runs")
      paragraph.call("#{rows.count { |row| row['status'] == 'validated' }}/#{rows.length} initial outputs validated. Three repetitions per language-specific passage; fresh processes. Timing includes startup, model load, synthesis and original-format file output, excluding decode verification. These are not normalized MP3-export or resident-engine timings.")
      table.call(["Engine", "Passage", "Median complete audio s", "Median audio duration s"],
        rows.group_by { |row| [row.fetch("engine"), row.fetch("sample")] }.map do |(engine, sample), group|
          valid = group.select { |row| row["status"] == "validated" }
          [engine, sample, number(median(valid.map { |row| row["command_wall_s"] })), number(median(valid.map { |row| row["audio_duration_s"] }))]
        end)
      paragraph.call("Piper runs use sherpa-onnx 1.13.8 and its converted Faber ONNX, not the application's separately checksum-validated original Faber artifact. Converted Faber SHA256: 956b4f1733903891c4ba0973d0603b2a3d8c09c8432fb3bb5203a90a7431daca; original application catalog SHA256: 858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7. Do not substitute these artifacts silently. Apple results use /usr/bin/say, not the app's Swift/FFI adapter. These are provider/model-family priorities, not measured app-adapter performance. Child RSS, where retained, excludes Apple helper services.")
    end
    heading.call("Terminal concurrency comparison")
    local = Dir.glob(File.join(root, "terminal-parallel/local/*/report.json")).filter_map { |path| read(path) }
    remote = Dir.glob(File.join(root, "terminal-parallel/*-c*/report.json")).filter_map { |path| read(path) }
    [[:local, local], [:remote, remote]].each do |kind, reports|
      attempts = reports.flat_map { |report| report.fetch("runs") }
      paragraph.call("#{kind}: #{attempts.count { |row| row['status'] == 'validated' }}/#{attempts.length} validated requests across #{reports.length} batches. Each batch uses four repeated short requests. Client/process overlap does not establish server worker count or phone feasibility.")
      table.call(["Configuration", "Clients", "Batch generation s", "Median first non-silent PCM, request s", "Statuses"], reports.map do |report|
        rows = report.fetch("runs")
        pcm = rows.filter_map { |row| row.dig("transport", "first_non_silent_pcm_request_s") }
        [report.fetch("engines").first.fetch("id"), report.fetch("concurrency"), number(report["generation_batch_wall_s"]),
         pcm.empty? ? "not measured" : number(median(pcm)), rows.group_by { |row| row.fetch("status") }.transform_values(&:length).to_json]
      end)
    end
    heading.call("Other free hosted demos")
    demos = read(File.join(root, "online-hf/smoke-index.json")) || []
    table.call(["Demo", "Result", "Complete downloaded audio s", "HTTP"], demos.map do |entry|
      report = entry.fetch("report")
      [entry.fetch("configuration"), report.fetch("status"), number(report["complete_audio_file_persisted_s"]), report["http_status"] || "unknown"]
    end)
    paragraph.call("Qwen, Chatterbox and Kitten demos returned complete-file responses; these are single smoke requests, not sustained streaming/concurrency evidence. VoxCPM refusal/503 is preserved without retry. Public demo availability is not a production SLA or a guaranteed free API entitlement. No confirmed public Piper endpoint was available: localhost serving would measure local compute plus HTTP, not cloud inference.")
    heading.call("Whole chapter in one external generation job")
    whole = %w[local edge].flat_map do |kind|
      report = read(File.join(root, "chapter-whole-#{kind}/report.json"))
      report ? report.fetch("runs") : []
    end
    table.call(["Engine", "Result", "Observed command s", "Audio min", "Generation/audio ratio"], whole.map do |row|
      duration = row["status"] == "validated" ? row["audio_duration_s"] : nil
      [row.fetch("engine"), row.fetch("status"), number(row["command_wall_s"]), duration ? number(duration / 60) : "unverified",
       duration ? number(row.fetch("command_wall_s") / duration) : "unverified"]
    end)
    paragraph.call("This is a separate export-throughput baseline using the same complete chapter text. Local voices load once per external job. Edge uses edge-tts 7.3.1 internal protocol splitting and a 90-second client deadline; it is not one giant SSML request. Completion excludes post-batch decoding. This baseline has no position-aware delivery or first-PCM timing and is not a substitute for the block-based listening experiment. Default speaking rates differ; compare text coverage and generation time alongside audio duration.")
    diagnosis = read(File.join(root, "edge-whole-timeout-diagnosis.json"))
    if diagnosis
      paragraph.call("The Edge whole-job attempt failed after #{number(diagnosis.fetch('observed_command_s'))} seconds: asyncio.timeout expired at the configured 90-second client deadline while the SDK awaited WebSocket receive. The 120-second supervisor deadline did not fire. A 2,269,440-byte partial MP3 decodes as 378.24 seconds of audio; it is not a completed chapter. No explicit HTTP 429 or Retry-After was observed in that attempt. The user had already reported Edge rate limits: successful short trials do not refute that report, and throttling without an explicit response remains possible. This client had no frame timeline, so the underlying service delay is unresolved.")
    end
    heading.call("Hybrid block size comparison")
    hybrids = Dir.glob(File.join(root, "hybrid-*-c*/report.json")).filter_map { |path| [File.basename(File.dirname(path)), read(path)] }
    table.call(["Configuration", "Valid/expected", "Generate + persist s", "Single MP3 + verification s", "First complete block s", "Replay gap 1x s", "Replay gap 2x s"], hybrids.map do |name, report|
      rows = report.fetch("runs")
      complete = rows.length == report.fetch("samples").length
      normal = complete ? TTSChapterBenchmark.playback(rows) : {}
      fast = complete ? TTSChapterBenchmark.playback(rows, speed: 2.0) : {}
      export = read(File.join(root, name, "chapter-export.json"))
      total = export ? number(report.fetch("batch_and_validation_wall_s") + export.fetch("assembly_and_validation_s")) : "not assembled"
      [name, "#{rows.count { |row| row['status'] == 'validated' }}/#{report.fetch('samples').length}", number(report["generation_batch_wall_s"]), total,
       number(normal["first_complete_mp3_s"]), number(normal["stall_total_s"]), number(fast["stall_total_s"])]
    end)
    paragraph.call("Hybrid plans preserve the same chapter and first two 96/351-character blocks, then coalesce remaining sentence-aligned blocks up to 2,000 characters: 16 blocks rather than 59. Local commands/encoding stay the same. Edge uses an archived variant of the same PCM probe with only its input guard extended from 500 to 3,000 characters; the maximum actual block is 1,999. This varies request/model-load overhead while retaining a short start. One run per case; no global optimum is established. Local concurrency is capped at two; online hybrid trials include one, two and four clients.")
    paragraph.call("The main chapter configurations ran in fixed serial-then-parallel order. Edge's per-request latency also changed substantially between those periods, so the entire batch-time ratio cannot be assigned to concurrency alone. An additional late serial repetition was omitted to bound runtime at the user's request; server-side caching and deployment conditions remain uncontrolled.")
    heading.call("Full chapter and listening from the middle")
    chapter = read(File.join(root, "chapter-final-01/summary.json"))
    if chapter
      paragraph.call("Akita chapter 11, Como se mede uma IA: #{chapter.fetch('chapter_characters')} characters / #{chapter.fetch('chapter_utf8_bytes')} UTF-8 bytes; SHA256 #{chapter.fetch('chapter_sha256')}. All text is retained across #{chapter.fetch('chunks')} blocks. First block limit 180 characters, subsequent limit 480; sentence/word boundaries preferred. The middle starts at character offset #{chapter.fetch('middle_offset')}. Next-chapter probe uses the first two blocks of chapter 12. Campaign: #{chapter['finished_utc'] ? 'finished' : 'in progress'}.")
      table.call(["Engine", "Scenario", "Validated/expected", "Generate + persist blocks s", "Complete MP3 + verification s", "Audio min", "First complete block s", "Replay stalls 1x / 2x"], chapter.fetch("runs").map do |run|
        batch = File.join(root, "chapter-final-01", run.fetch("id"))
        export = read(File.join(batch, "chapter-export.json"))
        total = export ? number(run.fetch("with_validation_s") + export.fetch("assembly_and_validation_s")) : "pending"
        [run.fetch("engine"), run.fetch("scenario"), "#{run.fetch('statuses').fetch('validated', 0)}/#{run.fetch('expected_chunks')}",
         number(run.fetch("generation_s")), total, number(run.fetch("audio_duration_s") / 60),
         number(run.dig("playback_1x", "first_complete_mp3_s")),
         "#{run.dig('playback_1x', 'stall_count') || 'pending'} / #{run.dig('playback_2x', 'stall_count') || 'pending'}"]
      end)
      paragraph.call("The export column includes post-batch block verification, MP3 stream-copy assembly and final assembled-file verification. First-block and batch times start after manifest validation; startup before that clock and gaps between separately invoked phases are excluded. Per-block complete-MP3 time is conservative relative to incremental delivery. Edge also records first decoded non-silent PCM, which is not speaker output. Original Edge MP3 is preserved; WAV providers are encoded as mono 24 kHz/48 kbps. Fresh processes intentionally include repeated model startup. Parallel full-chapter runs and serial runs are single observations, not p95 estimates.")
      table.call(["Middle-start engine", "Lead s", "Predicted next-chapter gap 1x s", "Predicted next-chapter gap 2x s"], chapter.fetch("runs").select { |run| run["scenario"] == "middle-c1" }.map do |run|
        [run.fetch("engine"), 60, number(run.dig("next_prefetch_1x", "predicted_boundary_gap_s")), number(run.dig("next_prefetch_2x", "predicted_boundary_gap_s"))]
      end)
      paragraph.call("Continuity and prefetch are offline trace replays using actual completion times and decoded durations, assuming immediate playback of complete blocks and a 60-second experimental lead. They do not exercise an actual player, Rust scheduler, variable network, mobile suspension or audio-route changes. On a long chapter, prefetch must follow remaining playable time; at a chapter tail shorter than generation latency it must begin immediately or expose a gap.")
      table.call(["Engine/scenario at 2x", "One-block start s", "One-block gap s", "Two-block start s", "Two-block gap s"], chapter.fetch("runs").select { |run| run["scenario"].start_with?("full-") }.map do |run|
        raw = read(File.join(root, "chapter-final-01", run.fetch("id"), "report.json"))
        buffered = raw ? buffer_replay(raw.fetch("runs"), speed: 2.0, blocks: 2) : {}
        [run.fetch("id"), number(run.dig("playback_2x", "first_complete_mp3_s")), number(run.dig("playback_2x", "stall_total_s")),
         number(buffered["first_playback_s"]), number(buffered["stall_total_s"])]
      end)
      paragraph.call("The two-block replay is an illustrative startup-buffer tradeoff, not an implemented app default. A tiny first block can start quickly yet contain too little audio to cover the next cold model load at 2x. Prefer a playback-time-based buffer and measured generation speed; two blocks can represent very different durations. Faster chapter export does not by itself guarantee gap-free first playback.")
    end
    heading.call("Position change and failure handling")
    seeks = Dir.glob(File.join(root, "seek-final-*/report.json")).filter_map { |path| [File.basename(File.dirname(path)), read(path)] }
    table.call(["Engine job", "Result", "Cancel/reap s", "Seek to target MP3 s", "Exact new identity"], seeks.map do |name, report|
      [name, report.fetch("status"), number(report["cancel_and_reap_s"]), number(report["seek_to_complete_target_mp3_s"]), report["new_sample_identities_match"]]
    end)
    paragraph.call("Host regressions exercise actual child-process overlap, timeout/reaping, cancellation, failure exit status, refusal preventing pending requests, Unicode/quoted text, ordered export and modified-source/audio rejection. Synthetic 401/429 fixtures prove stop behavior, not a real service rate threshold. Seek timing includes cancellation and new-batch startup, using persisted-MP3 monotonic telemetry when available; otherwise it is a replacement-batch upper bound. It is not app seek latency. Actual network refusal or timeout is preserved; no paid endpoint, quota evasion or intentional exhaustion is used.")
    heading.call("Edge timeout diagnosis and rollout limits")
    paragraph.call("Source audit at isolated base 468e8b66 found distinct Edge paths: 25/60-second network-attempt deadlines, a raw 180/300-second chapter deadline, a length-aware typed-preferences path and a legacy five-second fallback branch. The active app build/dispatch branch was not identified. The five-second value is not a universal Edge chapter limit. Receiving frames does not necessarily reset an absolute deadline. These terminal clients do not reproduce the application's Rust transport; successful chapter runs cannot rule out an app-path timeout, missing turn.end, slow sink or ordering/backpressure problem.")
    deadlines = read(File.join(root, "edge-chapter-deadline-observations.json"))
    if deadlines
      table.call(["Serial Edge chapter metric", "Requests", "Median s", "Maximum s", "Over 5 s"], deadlines.map do |name, values|
        [name, values.fetch("n"), number(values["median"]), number(values["max"]), values.fetch("over_5s")]
      end)
      paragraph.call("In this completed serial chapter, 19/59 requests needed more than five seconds to persist the complete MP3, while every first non-silent PCM arrival was below five seconds. This makes an absolute five-second whole-operation budget a concrete suspect worth reproducing at the active Rust branch. It does not prove that branch was used, that its timing equals the Python client's phases, or that rate limiting caused the reported app timeout.")
    end
    paragraph.call("Proposed delivery policy: position/page-to-text mapping, ordered small blocks, priority for the selected position, chapter-only durable caching by default, next-chapter prefetch near the boundary, bounded per-provider concurrency and retries with Retry-After/backoff. Include book/chapter/text/model/voice/settings identity in cache keys; discard stale completions after seek. This is a design recommendation, not implemented behavior. Silence skipping remains deferred; generation speed and playback silence removal are different concerns.")
    heading.call("Acceptance matrix")
    table.call(["Concern", "Evidence or remaining work"], [
      ["Full chapter and middle offset", "Real text-to-MP3 jobs above; exact corpus hashes and ordered block manifests retained."],
      ["Playback continuity at 1x/2x", "Trace replay only. Actual audio device, player buffering and decoder handoff remain untested."],
      ["Open page/player position mapping", "Desired behavior accepted; EPUB page-to-text and current-player offset mapping were not exercised."],
      ["Next chapter", "Real first-two-block generation; trigger/transition evaluated by trace replay with a 60-second experimental lead."],
      ["Seek and stale jobs", "Terminal cancellation/replacement probe above; app queue identity and cross-job cache acceptance remain pending."],
      ["Provider limits and retries", "Controlled refusal/timeout fixtures, bounded client concurrency and stop-on-refusal. Adaptive retries/Retry-After recovery and a real quota ceiling are not validated."],
      ["Very large chapters", "One 24,028-character chapter measured. Larger chapters need bounded disk/queue budgets, checkpoints and cancellation without an unbounded chapter deadline."],
      ["Pause/background/offline transitions", "Not exercised. Mobile suspension, interruptions, power/thermal limits and persisted resume need device acceptance."],
      ["Warm engines/connections", "Not measured. Resident models/session reuse may change speed and RAM; fresh-process rankings cannot establish that result."],
      ["Voice fidelity and joins", "Decoding/non-silence verified; blind listening, omitted/repeated speech, sentence prosody, MP3 joins and pronunciation still need review."]])
    paragraph.call("No pronunciation-error rate, blind listening score, speaker-start latency, real-world rate-limit ceiling, energy/RAM-on-phone or mobile background acceptance has been established. No claim that all free online models were exhaustively tested: unavailable, paid, gated or undocumented routes are excluded with their reasons in the source research.")
    heading.call("Upstream references and provenance")
    paragraph.call("Runtime/model/client source references: https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8 ; https://huggingface.co/rhasspy/piper-voices ; https://github.com/rany2/edge-tts ; https://huggingface.co/kyutai/pocket-tts-without-voice-cloning . Exact installed assets, voice IDs, source revisions/hashes, endpoint schemas and licensing caveats are preserved with the private manifests and source reviews. A source-supported platform target is not measured device acceptance.")
    sections
  end

  def self.markdown(sections)
    lines = ["# Book TTS benchmark — consolidated evidence", "", "Updated: #{Time.now.utc.iso8601}.", ""]
    sections.each do |section|
      if section[:heading]
        lines.concat(["## #{section.fetch(:heading)}", ""])
      elsif section[:text]
        lines.concat([section.fetch(:text), ""])
      else
        escape = ->(value) { value.to_s.gsub("|", "\\|").gsub("\n", " ") }
        lines << "| #{section.fetch(:headers).map(&escape).join(' | ')} |"
        lines << "| #{section.fetch(:headers).map { '---' }.join(' | ')} |"
        section.fetch(:rows).each { |row| lines << "| #{row.map(&escape).join(' | ')} |" }
        lines << ""
      end
    end
    lines.join("\n")
  end

  def self.html(sections, root)
    escape = ->(value) { ERB::Util.html_escape(value.to_s) }
    body = sections.map do |section|
      if section[:heading]
        "<h2>#{escape.call(section.fetch(:heading))}</h2>"
      elsif section[:text]
        "<p>#{escape.call(section.fetch(:text))}</p>"
      else
        headers = section.fetch(:headers).map { |header| "<th>#{escape.call(header)}</th>" }.join
        rows = section.fetch(:rows).map { |row| "<tr>#{row.map { |value| "<td>#{escape.call(value)}</td>" }.join}</tr>" }.join
        "<div class=table><table><thead><tr>#{headers}</tr></thead><tbody>#{rows}</tbody></table></div>"
      end
    end.join("\n")
    players = Dir.glob(File.join(root, "chapter-final-01/*-middle-c1/chapter.mp3")).map do |path|
      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      "<p>#{escape.call(File.basename(File.dirname(path)))}</p><audio controls preload=none src=\"#{escape.call(relative)}\"></audio>"
    end.join("\n")
    <<~HTML
      <!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
      <title>Book TTS benchmark</title><style>body{font:16px/1.55 system-ui;max-width:1250px;margin:2rem auto;padding:0 1rem;color:#16313b;background:#f8fbfc}h1,h2{color:#075b64}.table{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px}th,td{border:1px solid #bbd0d4;padding:.5rem;text-align:left}th{background:#e4f0f2}audio{width:min(100%,650px)}a{color:#075b64}</style>
      <h1>Book TTS benchmark</h1><p>Updated #{Time.now.utc.iso8601}. <a href="Benchmark-consolidado.md">Markdown</a> · <a href="listening.html">Initial listening samples</a> · <a href="chapter-final-01/summary.json">Chapter raw summary</a></p>
      #{body}<h2>Listen from the middle of chapter 11</h2><p>Files are available for human review. No listening score has been assigned.</p>#{players}</html>
    HTML
  end

  def self.run(root, repository_note = nil)
    root = File.realpath(root)
    content = sections(root)
    markdown = markdown(content)
    File.write(File.join(root, "Benchmark-consolidado.md"), markdown)
    File.write(File.join(root, "final.html"), html(content, root))
    if repository_note
      reproduction = <<~MARKDOWN

        ## Reproduction

        Private corpus, audio, exact argv, model hashes, experiment plans and source snapshots are retained in the Obsidian AI Memory vault under `Curadas/Mac/Codex/epubtomp3/2026-10-23-book-tts`. No book text/audio or model weights are published with this documentation.

        Set the task-specific variables below to the preserved, reviewed inputs and **new output directories inside that vault**. Omit the Edge manifest for an offline-only run. The chapter script performs synthesis; use the initial harness dry run to verify each manifest first.

        ```sh
        mise run tts:benchmark:test -- --output "$TTS_NEW_CHECKS_DIRECTORY"
        mise exec -- ruby scripts/tts_book_benchmark.rb --manifest "$TTS_LOCAL_MANIFEST" --dry-run
        mise exec -- ruby scripts/tts_chapter_benchmark.rb \\
          --manifest "$TTS_LOCAL_MANIFEST" --manifest "$TTS_EDGE_MANIFEST" \\
          --text "$TTS_CHAPTER_TEXT" --sha256 "$TTS_CHAPTER_SHA256" \\
          --next-text "$TTS_NEXT_CHAPTER_TEXT" --output "$TTS_NEW_OUTPUT_DIRECTORY"
        ```

        `scripts/tts_parallel_benchmark.rb` executes a reviewed plan at a chosen concurrency; `scripts/tts_seek_benchmark.rb` measures cancellation/replacement; `scripts/tts_chapter_finalize.rb` joins only complete, ordered, hash-matching blocks; `scripts/tts_benchmark_consolidate.rb` regenerates this document and the private HTML. None of these commands builds or launches the app, changes provider defaults, downloads models or enables a paid service.
      MARKDOWN
      File.write(repository_note, markdown + reproduction)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: EVIDENCE_ROOT [REPOSITORY_MARKDOWN]" unless (1..2).cover?(ARGV.length)
  TTSBenchmarkConsolidate.run(*ARGV)
end
