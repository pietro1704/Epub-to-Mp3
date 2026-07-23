// PythonBridge.swift
//
// Thin Swift wrappers around the canonical Python pipeline modules
// embedded in the iOS bundle (see `python_app/src/`). Calling into
// these from Swift means the iOS app, the macOS sidecar, and the HF
// Spaces backend all run the SAME parser / cache / chunker / validator
// code. No more Swift reimplementations of EPUB parsing.
//
// Network I/O remains in Swift (`EdgeTTSBridge.swift`,
// `URLSessionWebSocketTask`) because iOS cannot `dlopen` libpython's
// `_socket`/`_ssl` extensions. The Edge-TTS path injects bytes back
// into Python only for retry/validation orchestration; that wiring is
// scoped for a follow-up slice.
//
// Bootstrap requirements (run once before building):
//   ios/EpubToMp3/scripts/bootstrap-ios-python.sh
//
// macOS still uses the sidecar path (`SidecarManager.swift`). This
// file only compiles on iOS / simulator.

import Foundation

enum PythonBridgeError: Error, LocalizedError {
    case bootstrapFailed(String)
    case parseFailed(String)
    case decodeFailed(String)
    case emptyResult
    case convertFailed(String)

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let m): return "Python bootstrap failed: \(m)"
        case .parseFailed(let m): return "Python parse failed: \(m)"
        case .decodeFailed(let m): return "Python result decode failed: \(m)"
        case .emptyResult: return "Python parser produced no chapters"
        case .convertFailed(let m): return "Python convert failed: \(m)"
        }
    }
}

#if os(iOS) || targetEnvironment(simulator)

import PythonKit

/// Synchronisation gate around in-process Python calls. PythonKit
/// surfaces CPython through a single interpreter, which is not
/// thread-safe; we serialise calls on a dedicated dispatch queue so
/// concurrent SwiftUI `Task`s don't race on the GIL boundary.
final class PythonBridge: @unchecked Sendable {
    static let shared = PythonBridge()

    /// Single-threaded executor for every PythonKit call. Pins every
    /// Python call to a dedicated kernel thread for the process lifetime
    /// (actors can't do this — they guarantee mutual exclusion, not
    /// thread affinity, and custom executors need iOS 17+).
    private let runner = PythonRunner.shared

    /// Cached `python_app.src.ios_entrypoints` module handle. Without
    /// this cache every chapter synthesis re-runs `attemptImport`,
    /// which under memory pressure has been observed to crash inside
    /// `_PyObject_Malloc` during repeat ``PyImport_ImportModule``
    /// invocations. Module handles in CPython are forever-cached in
    /// ``sys.modules``; once we own a strong PythonObject reference
    /// we never need to ask the import machinery again.
    /// Access only from `queue`.
    private var _iosEntrypointsModule: PythonObject?

    private init() {}

    // MARK: - EPUB parse

    /// Parses an EPUB on disk via `python_app.src.ebook_reader.parse_epub_to_dict`,
    /// the same function the macOS sidecar exposes through
    /// `GET /api/jobs/{id}/fulltext`. Returns an `EbookFulltext` already
    /// decoded into the model the SwiftUI reader expects — same wire
    /// shape, same code path, no Swift-side parser to maintain.
    ///
    /// - Parameters:
    ///   - fileURL: on-disk location of the `.epub`.
    ///   - bookId: SHA-256 content hash from `LibraryStore`; propagated
    ///     as `EbookFulltext.jobId` so downstream caches keyed on
    ///     `jobId` line up with what the backend would have returned.
    /// - Throws: `PythonBridgeError` if bootstrap, parse, or JSON
    ///   decode fails.
    func parseEpub(at fileURL: URL, bookId: String) async throws -> EbookFulltext {
        // 30 s deadline via PythonRunner's one-resume gate (not
        // `withTimeout`, which deadlocks around continuations — see
        // PythonRunner.callAsync(timeout:) doc).
        try await runner.callAsync(timeout: 30, label: "EPUB parse") {
            try PythonEmbed.shared.bootstrap()
            return try self.parseEpubSync(path: fileURL.path, bookId: bookId)
        }
    }

    /// Same as `parseEpub(at:bookId:)` but synchronous. Marked private
    /// because callers MUST land on `queue` first to avoid GIL races.
    private func parseEpubSync(path: String, bookId: String) throws -> EbookFulltext {
        // Prefer the bootstrap-thread preload (avoids the
        // ``_PyObject_Malloc`` malloc crash observed when
        // ``PyImport_ImportModule`` runs on a worker that didn't run
        // ``Py_Initialize``). Fall back to an on-demand import if the
        // preload failed — caller surfaces the underlying Python error.
        let reader: PythonObject
        do {
            reader = try PythonEmbed.shared.ensureEbookReader()
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ebook_reader: \(error)"
            )
        }

        let pyResult = reader.parse_epub_to_dict(path, bookId)

        // Cross the Swift boundary as JSON. The Python helper already
        // emits keys that match `EbookFulltext`'s `Codable` shape; we
        // just need a serialisable container.
        let json: PythonObject
        do {
            json = try Python.attemptImport("json")
        } catch {
            throw PythonBridgeError.decodeFailed("import json: \(error)")
        }
        guard let jsonText = String(json.dumps(pyResult)) else {
            throw PythonBridgeError.decodeFailed("json.dumps returned non-string")
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw PythonBridgeError.decodeFailed("UTF-8 encode failed")
        }
        let decoded: EbookFulltext
        do {
            decoded = try JSONDecoder().decode(EbookFulltext.self, from: data)
        } catch {
            throw PythonBridgeError.decodeFailed("\(error)")
        }
        guard !decoded.chapters.isEmpty else {
            throw PythonBridgeError.emptyResult
        }
        return decoded
    }

    // MARK: - Chapter conversion (Python pipeline + Swift transport)

    /// Synthesises one chapter through the canonical Python pipeline.
    ///
    /// Internally calls
    /// `python_app.src.ios_entrypoints.synthesize_chapter_via_transport`,
    /// which chunks `text` and invokes the currently-installed Edge-TTS
    /// transport per chunk. `PythonEmbed.bootstrap()` registers
    /// `EdgeTTSBridge` as that transport at app launch, so on iOS the
    /// chunks go out over `URLSessionWebSocketTask` (Swift owns the
    /// socket) while Python keeps owning the orchestration (chunking,
    /// validation, future retry / fallback).
    ///
    /// This replaces the direct `EdgeTTSBridge().synthesize(...)` path
    /// that `PythonEmbed.convertWithEdgeTTS` used during the spike --
    /// the iOS app and the macOS sidecar now share a single conversion
    /// pipeline, the only difference being which transport is wired
    /// into `_edge_transport`.
    func convertChapter(
        text: String, voice: String, outputDir: URL
    ) async throws -> URL {
        try await runner.callAsync {
            try PythonEmbed.shared.bootstrap()
            return try self.convertChapterSync(
                text: text, voice: voice, outputDir: outputDir
            )
        }
    }

    private func convertChapterSync(
        text: String, voice: String, outputDir: URL
    ) throws -> URL {
        let outURL = outputDir.appendingPathComponent(
            "edge_\(UUID().uuidString).mp3"
        )
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        // Pre-imported in ``PythonEmbed.bootstrap``; see the matching
        // guard in ``convertChapterStreamingSync`` for the malloc-crash
        // rationale.
        let entry: PythonObject
        do {
            entry = try PythonEmbed.shared.ensureIosEntrypoints()
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ios_entrypoints: \(error)"
            )
        }

        do {
            _ = try entry.synthesize_chapter_via_transport.throwing.dynamicallyCall(
                withArguments: [text, voice, outURL.path]
            )
        } catch {
            throw PythonBridgeError.convertFailed(
                "synthesize_chapter_via_transport: \(error)"
            )
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw PythonBridgeError.parseFailed(
                "ios_entrypoints did not write \(outURL.path)"
            )
        }
        return outURL
    }

    // MARK: - Parallel chunk synthesis

    /// Maximum concurrent Edge WebSocket connections per chapter.
    /// Matches desktop ``EDGE_MAX_CONCURRENCY`` default. On iOS the
    /// system URLSession pool naturally limits to ~6 concurrent TCP
    /// connections per host, so 6 is the practical ceiling.
    private static let maxChunkConcurrency = 6

    /// Synthesises one chapter with chunk-level parallelism.
    ///
    /// Instead of the serial Python loop (one chunk at a time via the
    /// transport semaphore), this path:
    /// 1. Calls ``prepare_chunks`` on the Python thread to get the
    ///    pre-split text array (fast, no network).
    /// 2. Fires up to ``maxChunkConcurrency`` concurrent
    ///    ``EdgeTTSBridge.synthesize`` calls from Swift's cooperative
    ///    thread pool (each opens its own WebSocket).
    /// 3. Reassembles MP3 bytes in chunk order and writes the file.
    ///
    /// This mirrors the desktop path's ``EDGE_MAX_CONCURRENCY=12``
    /// parallelism but at the Swift networking layer.
    func convertChapterParallel(
        text: String,
        voice: String,
        outputDir: URL,
        chapterIndex: Int,
        onSegment: (@MainActor @Sendable (Data, Int, Int) -> Void)? = nil
    ) async throws -> URL {
        guard PythonEmbed.shared.isBootstrapComplete else {
            throw PythonBridgeError.bootstrapFailed("interpreter not ready yet")
        }

        // Step 1: Get chunks from Python (runs on Python thread, fast).
        let (chunks, resolvedVoice) = try await runner.callAsync {
            try self.prepareChunksSync(text: text, voice: voice, streaming: onSegment != nil)
        }

        guard !chunks.isEmpty else {
            throw PythonBridgeError.emptyResult
        }

        let outURL = outputDir.appendingPathComponent(
            "edge_par_\(UUID().uuidString).mp3"
        )
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        // Step 2: Synthesize chunks in parallel with bounded concurrency.
        let results = try await synthesizeChunksParallel(
            chunks: chunks,
            voice: resolvedVoice,
            chapterIndex: chapterIndex,
            onSegment: onSegment
        )

        // Step 3: Concatenate in order and write.
        var audio = Data()
        for data in results {
            audio.append(data)
        }
        guard !audio.isEmpty else {
            throw PythonBridgeError.convertFailed("all chunks returned empty audio")
        }
        try audio.write(to: outURL)
        return outURL
    }

    private func prepareChunksSync(
        text: String, voice: String, streaming: Bool
    ) throws -> ([String], String) {
        let entry: PythonObject
        do {
            entry = try PythonEmbed.shared.ensureIosEntrypoints()
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ios_entrypoints: \(error)"
            )
        }
        let result = entry.prepare_chunks(text, voice, streaming)
        guard let chunkList = Array<String>(result["chunks"]) else {
            throw PythonBridgeError.decodeFailed("prepare_chunks: can't decode chunks")
        }
        let resolved = String(result["voice"]) ?? voice
        return (chunkList, resolved)
    }

    private func synthesizeChunksParallel(
        chunks: [String],
        voice: String,
        chapterIndex: Int,
        onSegment: (@MainActor @Sendable (Data, Int, Int) -> Void)?
    ) async throws -> [Data] {
        // Pre-allocate result array to maintain order.
        var results = [Data?](repeating: nil, count: chunks.count)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var launched = 0

            for (index, chunk) in chunks.enumerated() {
                // Throttle: wait for a slot if we've hit max concurrency.
                if launched >= Self.maxChunkConcurrency {
                    if let (idx, data) = try await group.next() {
                        results[idx] = data
                        if let cb = onSegment {
                            let capturedIdx = chapterIndex
                            let capturedSeg = idx
                            let capturedData = data
                            Task { @MainActor in
                                cb(capturedData, capturedIdx, capturedSeg)
                            }
                        }
                    }
                }

                let chunkText = chunk
                group.addTask {
                    let bridge = EdgeTTSBridge()
                    let mp3 = try await withTimeout(
                        seconds: 60, label: "Edge chunk \(index)"
                    ) {
                        try await bridge.synthesize(
                            text: chunkText, voice: voice
                        )
                    }
                    return (index, mp3)
                }
                launched += 1
            }

            // Drain remaining.
            while let (idx, data) = try await group.next() {
                results[idx] = data
                if let cb = onSegment {
                    let capturedIdx = chapterIndex
                    let capturedSeg = idx
                    let capturedData = data
                    Task { @MainActor in
                        cb(capturedData, capturedIdx, capturedSeg)
                    }
                }
            }
        }

        // Convert [Data?] -> [Data], filtering nils (shouldn't happen
        // since we throw on errors, but be defensive).
        return results.compactMap { $0 }
    }

    // MARK: - Segment-streaming chapter conversion

    /// Segment-streaming variant of ``convertChapter``.
    ///
    /// Calls ``python_app.src.ios_entrypoints.synthesize_chapter_streaming``
    /// which delivers MP3 bytes to ``onSegment`` after each TTS chunk
    /// closes rather than accumulating all audio first. Swift's caller
    /// (`AudioPlayer.enqueueSegment`) writes the bytes to a temp file and
    /// inserts an `AVPlayerItem` into the running queue, so the first
    /// segment is playable within ~500 ms of synthesis start.
    ///
    /// The full concatenated MP3 is still written to disk at ``outPath``
    /// so the chapter-cache / resume path works unchanged.
    ///
    /// - Parameters:
    ///   - text: Chapter plain text (pre-processed, ready for TTS).
    ///   - voice: Edge-TTS voice name (e.g. `"pt-BR-FranciscaNeural"`).
    ///   - outputDir: Directory where the final chapter MP3 is written.
    ///   - chapterIndex: Zero-based index passed through to ``onSegment``.
    ///   - onSegment: Called on the *main actor* for each segment that
    ///     produces audio. Arguments: `(mp3Data, chapterIndex, segmentIndex)`.
    /// - Returns: URL of the completed (full) chapter MP3.
    func convertChapterStreaming(
        text: String,
        voice: String,
        outputDir: URL,
        chapterIndex: Int,
        onSegment: @MainActor @escaping (Data, Int, Int) -> Void
    ) async throws -> URL {
        guard PythonEmbed.shared.isBootstrapComplete else {
            throw PythonBridgeError.bootstrapFailed("interpreter not ready yet")
        }
        return try await runner.callAsync {
            try self.convertChapterStreamingSync(
                text: text,
                voice: voice,
                outputDir: outputDir,
                chapterIndex: chapterIndex,
                onSegment: onSegment
            )
        }
    }

    private func convertChapterStreamingSync(
        text: String,
        voice: String,
        outputDir: URL,
        chapterIndex: Int,
        onSegment: @MainActor @escaping (Data, Int, Int) -> Void
    ) throws -> URL {
        let outURL = outputDir.appendingPathComponent(
            "edge_stream_\(UUID().uuidString).mp3"
        )
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        // ``PythonEmbed.bootstrap()`` pre-imports
        // ``python_app.src.ios_entrypoints`` on the same thread that ran
        // ``Py_Initialize`` (see ``preloadHotModules``). Doing the
        // import here, on a different serial-queue worker, has crashed
        // inside ``_PyObject_Malloc`` / ``unicode_decode_utf8`` — so we
        // never call ``attemptImport`` from this hot path.
        let entry: PythonObject
        do {
            entry = try PythonEmbed.shared.ensureIosEntrypoints()
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ios_entrypoints: \(error)"
            )
        }
        _iosEntrypointsModule = entry

        // Build a Python callable that Swift will receive per segment.
        // PythonKit lets us pass a Swift closure as a Python callable via
        // `PythonFunction`. We bridge the bytes back to `Data` and hop
        // onto the main actor so `AudioPlayer.enqueueSegment` runs on
        // the right thread.
        let callback = PythonFunction { args in
            // args: (mp3_bytes: bytes, segment_index: int, total: int)
            guard args.count >= 2 else { return Python.None }
            let pyBytes = args[0]
            let segIdx = Int(args[1]) ?? 0
            // PythonKit can't `Data(bytes: PythonObject)` directly. The
            // documented bridge is `[UInt8](pyBytes)` which routes through
            // PythonKit's `PythonConvertible` conformance for sequences of
            // ints; from that we build a Swift `Data`.
            if let byteArray = [UInt8](pyBytes) {
                let raw = Data(byteArray)
                let capturedIdx = chapterIndex
                Task { @MainActor in
                    onSegment(raw, capturedIdx, segIdx)
                }
            }
            return Python.None
        }

        do {
            _ = try entry.synthesize_chapter_streaming.throwing.dynamicallyCall(
                withArguments: [text, voice, outURL.path, callback.pythonObject]
            )
        } catch {
            throw PythonBridgeError.convertFailed(
                "synthesize_chapter_streaming: \(error)"
            )
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw PythonBridgeError.parseFailed(
                "ios_entrypoints did not write \(outURL.path)"
            )
        }
        return outURL
    }

    // MARK: - Full-pipeline conversion (CLI superset)

    /// Options accepted by ``convertEpub(...)`` — mirrors the CLI flag
    /// surface of ``python -m python_app.main convert ...``. Every flag
    /// is optional so callers can specify only what they need; the
    /// defaults match the CLI defaults (Edge-only, no fallback).
    ///
    /// Namespaced inside ``PythonBridge`` to avoid a clash with
    /// ``APIClient.ConvertOptions`` (the network-side analogue used by
    /// the sidecar/HF Spaces backend).
    struct ConvertOptions: Sendable {
        // Slice-1a surface (honoured today).
        var voice: String = "auto"
        var engine: String = "edge"
        var fallbackEngine: String = "none"
        /// Either a single chapter id (``"3"``, ``"3.1"``) or a comma-
        /// separated list / repeated entries (``"1,2,3"``).
        var chapter: String?
        var clearCache: Bool = false
        var showStructure: Bool = false
        var maxChapterChars: Int = 0
        var noCache: Bool = false
        var forceReprocess: Bool = false
        var filterChapters: Bool = false

        // Parity surface (accepted, recorded in applied_options, not
        // yet load-bearing on iOS in this slice). Mirrors the CLI's
        // ``_add_conversion_arguments`` order.
        var batchDir: String?
        var engineChainFallback: Bool = false
        var prewarmEdge: Bool = false
        var prewarmPiper: Bool = false
        var injectTitlePauseMs: Int = 0
        var model: String?
        var detectLanguage: Bool = false
        var verbose: Bool?
        var formattingCues: Bool?
        var characterVoices: Bool?
        var narratorVoice: String?
        var characterVoice: String?
        var listen: Bool = false
        var exportToIphone: Bool?
        var noParallel: Bool = false
        var multiEngineParallel: Bool = false
        var noFootnote: Bool = false
        var footnoteChapterEnd: Bool = false
        var resumeFromFailure: Bool?
        var verifyOnly: Bool = false
        var fixMode: Bool = false
        var verifyTranscription: Bool?
        var deepValidate: Bool?
        var validateDuringConversion: Bool = false
        var autoValidateOutput: Bool?
        var autoFixOutput: Bool?
        var noValidate: Bool = false
        var validateText: Bool = true
        var validateAudio: Bool = true
        var strictValidate: Bool = false
        var transcriptionModel: String = "small"
        var validationLanguage: String?
        var fromChapterToEnd: String?
        var fromChapterToChapter: String?
        var sections: [String]?
        var priority: [String]?
        var language: String?
        var useLanguageDetection: Bool?
        var prioritizePrimaryLanguage: Bool?
        var uiLanguage: String?
        var maxPerformance: Bool = false
        var overnight: Bool = false
        var profile: String?
        var speedScenario: String = "auto"
        var parallelSlots: Int?
        var chapterStallSeconds: Double?
        var edgeChunkChars: Int?
        var edgeMaxSegmentSeconds: Int?
        var edgeNetworkTier: String?
        var edgeEnableParallel: Bool?
        var edgeAutoTune: Bool?
        var edgeStableMode: Bool?
        var piperMaxProcs: Int?
        var piperChunkChars: Int?
        var bitrate: String?
        var sampleRate: Int?
        var channels: Int?
        var healthCheckIntervalSeconds: Double?
        var healthCheckSlowEdgeCps: Double?
        var healthCheckSlowCps: Double?
        var healthCheckHighCpu: Double?
        var healthCheckHighMem: Double?
        var healthCheckOkCpu: Double?
        var healthCheckOkMem: Double?
        var healthCheckSlowStreak: Int?
        var retryFailed: Int?
        var retryFailedManual: Bool = false
        var showMetricsSummary: Bool = false
        var showMetricsDashboard: Bool = false
        var openMetricsDashboard: Bool = false
        var exportMetricsBundle: Bool = false
        var chapterPrefetch: Bool?
        var stagePipeline: Bool?
        var stagePipelineDepth: Int?
        var autoAb: Bool?
        var adaptiveCheckpoint: Bool?
        var stopOnError: Bool = false

        static let `default` = ConvertOptions()
    }

    /// Manifest entry produced by ``convertEpub(...)``. Field names match
    /// the Python ``ios_entrypoints.convert_epub`` payload exactly so
    /// the ``JSONDecoder`` translates without a ``CodingKeys`` map.
    struct ChapterEntry: Codable, Sendable {
        let index: String
        let name: String
        let level: Int
        /// Snake_case in Python; we use a custom decoder to preserve it
        /// without polluting downstream Swift call sites.
        let charCount: Int
        let status: String?
        let outputPath: String?
        let reason: String?
        let error: String?
        let voice: String?

        private enum CodingKeys: String, CodingKey {
            case index, name, level, status, reason, error, voice
            case charCount = "char_count"
            case outputPath = "output_path"
        }
    }

    /// Result returned by ``convertEpub(...)``. ``outputs`` is decoded
    /// straight to URLs for the SwiftUI player; ``errors`` is plain
    /// strings so the UI can render without further parsing.
    struct ConvertResult: Sendable {
        let bookTitle: String
        let bookAuthor: String
        let outputs: [URL]
        let manifest: [ChapterEntry]
        let errors: [String]
        let outputDir: URL?
        let cacheDir: URL?
        let showStructure: Bool
    }

    /// Run the full Python conversion pipeline against ``epubURL``.
    /// Internally calls ``python_app.src.ios_entrypoints.convert_epub``
    /// — the same code path covered by ``test_ios_entrypoints.py``.
    ///
    /// Edge-only this slice: ``options.engine`` defaults to ``"edge"``
    /// and ``options.fallbackEngine`` defaults to ``"none"``. Setting
    /// them to Piper throws on the Python side; we surface that as
    /// ``PythonBridgeError.convertFailed``.
    ///
    /// - Parameters:
    ///   - epubURL: source EPUB on disk (must exist).
    ///   - outputDir: where the MP3 tree should land (per-book
    ///     subdirectory is created inside).
    ///   - cacheDir: per-book text/audio cache root.
    ///   - voice: Edge voice id (e.g. ``"en-US-AriaNeural"``). Pass
    ///     ``"auto"`` to let Python pick based on book language.
    ///   - options: CLI flag superset (see ``ConvertOptions``).
    /// - Throws: ``PythonBridgeError`` on bootstrap / decode / engine
    ///   errors; ``FileNotFoundError`` paths bubble up as
    ///   ``.convertFailed``.
    func convertEpub(
        epubURL: URL,
        outputDir: URL,
        cacheDir: URL,
        voice: String = "auto",
        options: ConvertOptions = .default
    ) async throws -> ConvertResult {
        try await runner.callAsync {
            try PythonEmbed.shared.bootstrap()
            return try self.convertEpubSync(
                epubURL: epubURL,
                outputDir: outputDir,
                cacheDir: cacheDir,
                voice: voice,
                options: options
            )
        }
    }

    private func convertEpubSync(
        epubURL: URL,
        outputDir: URL,
        cacheDir: URL,
        voice: String,
        options: ConvertOptions
    ) throws -> ConvertResult {
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true
        )

        let entry: PythonObject
        do {
            entry = try PythonEmbed.shared.ensureIosEntrypoints()
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ios_entrypoints: \(error)"
            )
        }

        // Build the kwargs as `[(key, value)]` — PythonKit's
        // ``dynamicallyCall(withKeywordArguments:)`` takes this exact
        // shape so the values keep their PythonConvertible types
        // (Bool / Int / String / [String]) without flattening to
        // strings on the way through. Mirror the Python signature in
        // snake_case; ``ConvertOptions`` gives Swift idiomatic
        // camelCase on this side of the seam.
        var kwargs: [(key: String, value: PythonConvertible)] = [
            ("epub_path", epubURL.path),
            ("output_dir", outputDir.path),
            ("cache_dir", cacheDir.path),
            ("voice", voice),
            ("engine", options.engine),
            ("fallback_engine", options.fallbackEngine),
            ("clear_cache", options.clearCache),
            ("show_structure", options.showStructure),
            ("max_chapter_chars", options.maxChapterChars),
            ("no_cache", options.noCache),
            ("force_reprocess", options.forceReprocess),
            ("filter_chapters", options.filterChapters),
            ("engine_chain_fallback", options.engineChainFallback),
            ("prewarm_edge", options.prewarmEdge),
            ("prewarm_piper", options.prewarmPiper),
            ("inject_title_pause", options.injectTitlePauseMs),
            ("detect_language", options.detectLanguage),
            ("listen", options.listen),
            ("no_parallel", options.noParallel),
            ("multi_engine_parallel", options.multiEngineParallel),
            ("no_footnote", options.noFootnote),
            ("footnote_chapter_end", options.footnoteChapterEnd),
            ("verify_only", options.verifyOnly),
            ("fix_mode", options.fixMode),
            ("validate_during_conversion", options.validateDuringConversion),
            ("no_validate", options.noValidate),
            ("validate_text", options.validateText),
            ("validate_audio", options.validateAudio),
            ("strict_validate", options.strictValidate),
            ("transcription_model", options.transcriptionModel),
            ("max_performance", options.maxPerformance),
            ("overnight", options.overnight),
            ("speed_scenario", options.speedScenario),
            ("retry_failed_manual", options.retryFailedManual),
            ("show_metrics_summary", options.showMetricsSummary),
            ("show_metrics_dashboard", options.showMetricsDashboard),
            ("open_metrics_dashboard", options.openMetricsDashboard),
            ("export_metrics_bundle", options.exportMetricsBundle),
            ("stop_on_error", options.stopOnError),
        ]
        // Optional fields: only forward when set so Python's keyword
        // defaults handle the unset case. Skipping `None`-style
        // sentinels keeps the Python side honest (Optional[bool] vs
        // bool).
        if let v = options.chapter { kwargs.append(("chapter", v)) }
        if let v = options.batchDir { kwargs.append(("batch_dir", v)) }
        if let v = options.model { kwargs.append(("model", v)) }
        if let v = options.verbose { kwargs.append(("verbose", v)) }
        if let v = options.formattingCues { kwargs.append(("formatting_cues", v)) }
        if let v = options.characterVoices { kwargs.append(("character_voices", v)) }
        if let v = options.narratorVoice { kwargs.append(("narrator_voice", v)) }
        if let v = options.characterVoice { kwargs.append(("character_voice", v)) }
        if let v = options.exportToIphone { kwargs.append(("export_to_iphone", v)) }
        if let v = options.resumeFromFailure { kwargs.append(("resume_from_failure", v)) }
        if let v = options.verifyTranscription { kwargs.append(("verify_transcription", v)) }
        if let v = options.deepValidate { kwargs.append(("deep_validate", v)) }
        if let v = options.autoValidateOutput { kwargs.append(("auto_validate_output", v)) }
        if let v = options.autoFixOutput { kwargs.append(("auto_fix_output", v)) }
        if let v = options.validationLanguage { kwargs.append(("validation_language", v)) }
        if let v = options.fromChapterToEnd { kwargs.append(("from_chapter_to_end", v)) }
        if let v = options.fromChapterToChapter {
            kwargs.append(("from_chapter_to_chapter", v))
        }
        if let v = options.sections { kwargs.append(("sections", v)) }
        if let v = options.priority { kwargs.append(("priority", v)) }
        if let v = options.language { kwargs.append(("language", v)) }
        if let v = options.useLanguageDetection {
            kwargs.append(("use_language_detection", v))
        }
        if let v = options.prioritizePrimaryLanguage {
            kwargs.append(("prioritize_primary_language", v))
        }
        if let v = options.uiLanguage { kwargs.append(("ui_language", v)) }
        if let v = options.profile { kwargs.append(("profile", v)) }
        if let v = options.parallelSlots { kwargs.append(("parallel_slots", v)) }
        if let v = options.chapterStallSeconds {
            kwargs.append(("chapter_stall_seconds", v))
        }
        if let v = options.edgeChunkChars { kwargs.append(("edge_chunk_chars", v)) }
        if let v = options.edgeMaxSegmentSeconds {
            kwargs.append(("edge_max_segment_seconds", v))
        }
        if let v = options.edgeNetworkTier { kwargs.append(("edge_network_tier", v)) }
        if let v = options.edgeEnableParallel {
            kwargs.append(("edge_enable_parallel", v))
        }
        if let v = options.edgeAutoTune { kwargs.append(("edge_auto_tune", v)) }
        if let v = options.edgeStableMode { kwargs.append(("edge_stable_mode", v)) }
        if let v = options.piperMaxProcs { kwargs.append(("piper_max_procs", v)) }
        if let v = options.piperChunkChars { kwargs.append(("piper_chunk_chars", v)) }
        if let v = options.bitrate { kwargs.append(("bitrate", v)) }
        if let v = options.sampleRate { kwargs.append(("sample_rate", v)) }
        if let v = options.channels { kwargs.append(("channels", v)) }
        if let v = options.healthCheckIntervalSeconds {
            kwargs.append(("health_check_interval_seconds", v))
        }
        if let v = options.healthCheckSlowEdgeCps {
            kwargs.append(("health_check_slow_edge_cps", v))
        }
        if let v = options.healthCheckSlowCps {
            kwargs.append(("health_check_slow_cps", v))
        }
        if let v = options.healthCheckHighCpu {
            kwargs.append(("health_check_high_cpu", v))
        }
        if let v = options.healthCheckHighMem {
            kwargs.append(("health_check_high_mem", v))
        }
        if let v = options.healthCheckOkCpu { kwargs.append(("health_check_ok_cpu", v)) }
        if let v = options.healthCheckOkMem { kwargs.append(("health_check_ok_mem", v)) }
        if let v = options.healthCheckSlowStreak {
            kwargs.append(("health_check_slow_streak", v))
        }
        if let v = options.retryFailed { kwargs.append(("retry_failed", v)) }
        if let v = options.chapterPrefetch { kwargs.append(("chapter_prefetch", v)) }
        if let v = options.stagePipeline { kwargs.append(("stage_pipeline", v)) }
        if let v = options.stagePipelineDepth {
            kwargs.append(("stage_pipeline_depth", v))
        }
        if let v = options.autoAb { kwargs.append(("auto_ab", v)) }
        if let v = options.adaptiveCheckpoint {
            kwargs.append(("adaptive_checkpoint", v))
        }

        // `convert_epub(**kwargs)`. Anything the entrypoint raises
        // (FileNotFoundError, RuntimeError) becomes a PythonKit-thrown
        // ``PythonError``; we wrap it as ``.convertFailed`` so Swift
        // callers see a single error type.
        let pyResult: PythonObject
        do {
            pyResult = try entry.convert_epub.throwing.dynamicallyCall(
                withKeywordArguments: kwargs
            )
        } catch {
            throw PythonBridgeError.convertFailed("\(error)")
        }

        // Bounce through JSON so we get strict, decoder-driven mapping
        // instead of PythonKit's loose conversions. Cheap: the manifest
        // is tens of entries even for a 600-page book.
        let json: PythonObject
        do {
            json = try Python.attemptImport("json")
        } catch {
            throw PythonBridgeError.decodeFailed("import json: \(error)")
        }
        // json.dumps(pyResult, default=str) — `default=str` handles any
        // pathlib.Path that snuck into ``applied_options`` (Path is not
        // JSON-serialisable by default; ``str`` is). PythonKit handles
        // the keyword-argument form via Swift's labelled-call syntax.
        guard let jsonText = String(json.dumps(pyResult, default: Python.str)) else {
            throw PythonBridgeError.decodeFailed("json.dumps returned non-string")
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw PythonBridgeError.decodeFailed("UTF-8 encode failed")
        }

        struct RawPayload: Codable {
            let bookTitle: String
            let bookAuthor: String
            let outputs: [String]
            let manifest: [ChapterEntry]
            let errors: [String]
            let outputDir: String?
            let cacheDir: String?
            let showStructure: Bool

            private enum CodingKeys: String, CodingKey {
                case outputs, manifest, errors
                case bookTitle = "book_title"
                case bookAuthor = "book_author"
                case outputDir = "output_dir"
                case cacheDir = "cache_dir"
                case showStructure = "show_structure"
            }
        }

        let raw: RawPayload
        do {
            raw = try JSONDecoder().decode(RawPayload.self, from: data)
        } catch {
            throw PythonBridgeError.decodeFailed(
                "convert_epub payload: \(error)"
            )
        }

        return ConvertResult(
            bookTitle: raw.bookTitle,
            bookAuthor: raw.bookAuthor,
            outputs: raw.outputs.map { URL(fileURLWithPath: $0) },
            manifest: raw.manifest,
            errors: raw.errors,
            outputDir: raw.outputDir.map { URL(fileURLWithPath: $0) },
            cacheDir: raw.cacheDir.map { URL(fileURLWithPath: $0) },
            showStructure: raw.showStructure
        )
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
