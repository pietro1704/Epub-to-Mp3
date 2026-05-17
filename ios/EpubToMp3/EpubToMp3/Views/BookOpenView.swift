import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import NaturalLanguage
import os.log

private let playerLog = Logger(subsystem: "epub2mp3", category: "AudioPlayer")

/// Routes a tapped library book straight into the reader.
///
/// Pipeline (target: visible text in <100 ms on the second open):
///   1. Read the cached `EbookFulltext` from disk → render reader
///      immediately. No network, no waiting.
///   2. If the cache is empty, parse the EPUB on-device through
///      `PythonBridge` — calls the canonical `python_app.src.ebook_reader`
///      module embedded in the iOS bundle (same code as the macOS
///      sidecar) — still no network → render reader, save cache for
///      next time. On macOS the sidecar path handles this instead.
///   3. Kick off audio in the background: reattach to an existing
///      job if we know its id, otherwise submit a new conversion
///      via `/api/convert`. Either way the reader is already
///      displayed; chapters get audio added to `AVQueuePlayer` as
///      `chapterProgress[i].downloadUrl` lands via SSE.
struct BookOpenView: View {
    let book: BookEntity

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// Global audio player — receives conversion state (`isConverting`,
    /// `conversionProgress`, `firstChapterReady`) so `MiniPlayerBar`
    /// can show the spinner / conversion progress without requiring a
    /// loaded audio item.
    @EnvironmentObject private var globalPlayer: AudioPlayer

    @State private var phase: Phase = .resolving
    @State private var fulltext: EbookFulltext?
    @State private var jobSnapshot: JobSnapshot?
    @State private var statusBanner: String?       // top-of-screen "Generating audio…" hint
    @State private var hasAudio: Bool = false
    @State private var audioBootstrapTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?
    @State private var showingPicker = false
    /// Live watchdog over the active audio bootstrap. Started by
    /// ``startAudioBootstrap``; stopped in ``onDisappear`` and on any
    /// terminal-state branch. Cancels + auto-retries the bootstrap on
    /// stall; after 2 silent stalls surfaces a banner with manual retry.
    @State private var watchdog: ConversionWatchdog?
    /// `true` once the watchdog has surfaced the give-up banner so the
    /// UI shows an explicit retry CTA rather than the generic spinner.
    @State private var conversionStalled: Bool = false
    /// Resolved PDF document — set only for `book.fileType == .pdf`
    /// once `openFlow()` has loaded the file. Kept on `BookOpenView`
    /// (not inside `PdfReaderView`) so the same instance survives a
    /// toolbar action like "Listen" without re-opening the file.
    @State private var pdfDocument: PDFDocument?
    @State private var pdfPageIndex: Int = 0
    @State private var registeredFontURLs: [URL] = []

    enum Phase: Equatable {
        case resolving
        case ready                      // reader rendered, audio status in banner
        case unreadable(URL)            // local parser failed (DRM / malformed)
        case error(String)
    }

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Group {
            switch phase {
            case .resolving:
                ProgressView("Opening \(book.resolvedTitle)…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                // PDFs render via PDFView (HIG / Apple Books pattern).
                // The reflow `InstantReaderView` is for EPUB only;
                // forcing PDFs through it would strip layout, images,
                // and break the user's mental model of "a PDF page".
                if book.fileType == .pdf, let pdf = pdfDocument {
                    PdfReaderView(
                        document: pdf,
                        currentPageIndex: $pdfPageIndex
                    )
                } else if let fulltext {
                    InstantReaderView(
                        fulltext: fulltext,
                        snapshot: $jobSnapshot,
                        statusBanner: statusBanner,
                        hasAudio: hasAudio,
                        backendBaseURL: settings.useEmbeddedRuntime ? nil : settings.resolvedBaseURL,
                        coverPNG: book.coverPNG,
                        onRequestAudioRetry: { startAudioBootstrap() },
                        onRequestPlay: { chapterIdx, _ in startAudioBootstrap(startChapterIndex: chapterIdx) }
                    )
                    .environment(\.epubFontDirectory, registeredFontURLs.first?.deletingLastPathComponent())
                } else {
                    Text("No content available.")
                }

            case .unreadable(let fileURL):
                LocalEpubReaderView(fileURL: fileURL, book: book)

            case .error(let msg):
                errorView(message: msg)
            }
        }
        .navigationTitle(book.resolvedTitle)
        .compatInlineNavigationTitle()
        .task { await openFlow() }
        .onDisappear {
            audioBootstrapTask?.cancel()
            streamTask?.cancel()
            watchdog?.stop()
            watchdog = nil
            globalPlayer.clearConversionState()
            EpubFontManager.unregisterFonts(registeredFontURLs)
            registeredFontURLs = []
        }
        .background {
            Color.clear.allowsHitTesting(false)
                .fileImporter(
                    isPresented: $showingPicker,
                    allowedContentTypes: [.epub, .pdf],
                    allowsMultipleSelection: false
                ) { result in
                    handleRePick(result)
                }
        }
    }

    // MARK: - Flow

    @MainActor
    private func openFlow() async {
        if isSwiftUIPreview { phase = .ready; return }

        globalPlayer.clearConversionState()

        let bookId = book.id
        let fileURL: URL
        do {
            fileURL = try library.openBookFile(id: bookId)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        if book.fileType == .epub {
            let capturedURL = fileURL
            let fonts = await Task.detached(priority: .userInitiated) {
                let accessing = capturedURL.startAccessingSecurityScopedResource()
                defer { if accessing { capturedURL.stopAccessingSecurityScopedResource() } }
                return EpubFontManager.registerFonts(from: capturedURL)
            }.value
            self.registeredFontURLs = fonts
        }

        // PDF path: PDFKit is fully on-device; no Python parse needed.
        // We still extract pseudo-chapters via `PdfTextExtractor` so
        // the TTS conversion path (when the user taps Listen) has a
        // chapter manifest to feed the engine — but the reader is
        // `PdfReaderView`, not the reflow text view.
        if book.fileType == .pdf {
            // PDFDocument(url:) maps the entire file + parses xref on
            // the calling thread — easily 200-500 ms on a large PDF.
            // Hop to a detached task so the UI doesn't stall.
            let docResult: PDFDocument? = await Task.detached(
                priority: .userInitiated
            ) { PDFDocument(url: fileURL) }.value
            guard let doc = docResult else {
                phase = .unreadable(fileURL)
                return
            }
            if doc.isEncrypted && !doc.unlock(withPassword: "") {
                phase = .error("\(book.displayFilename) is password-protected. Remove the password before importing.")
                return
            }
            self.pdfDocument = doc
            // Best-effort pseudo-fulltext extraction. Failure here is
            // non-fatal — the reader still works; only audio is gated.
            let cachedPdf: EbookFulltext? = await Task.detached(
                priority: .userInitiated
            ) { LocalFulltextCache.read(bookId: bookId) }.value
            if let cached = cachedPdf {
                self.fulltext = cached
            } else {
                let capturedURL = fileURL
                let extracted: EbookFulltext? = await Task.detached(
                    priority: .userInitiated
                ) {
                    try? PdfTextExtractor.extract(
                        from: capturedURL, bookId: bookId
                    )
                }.value
                if let extracted {
                    self.fulltext = extracted
                    Task.detached(priority: .background) {
                        LocalFulltextCache.save(extracted, bookId: bookId)
                    }
                }
            }
            self.phase = .ready
            return
        }

        // 2. Try the on-disk fulltext cache first. Even on a fresh
        //    install of a book we built locally during the previous
        //    session, this hits.  Run off the main actor — even a
        //    small JSON read can stall during sandbox warm-up.
        let cachedEpub: EbookFulltext? = await Task.detached(
            priority: .userInitiated
        ) { LocalFulltextCache.read(bookId: bookId) }.value
        if let cached = cachedEpub {
            self.fulltext = cached
            self.phase = .ready
        } else {
            let accessing = fileURL.startAccessingSecurityScopedResource()

            var parsed: EbookFulltext?
            #if os(iOS)
            if PythonEmbed.shared.isParserAvailable {
                do {
                    parsed = try await PythonBridge.shared.parseEpub(
                        at: fileURL, bookId: book.id
                    )
                } catch {
                    parsed = nil
                }
            }
            #endif
            if parsed == nil || (parsed?.chapters.isEmpty ?? true) {
                let capturedURL = fileURL
                let capturedBookId = book.id
                let fallback: EbookFulltext = await Task.detached(
                    priority: .userInitiated
                ) {
                    let innerAccess = capturedURL.startAccessingSecurityScopedResource()
                    defer { if innerAccess { capturedURL.stopAccessingSecurityScopedResource() } }
                    return EpubFallbackParser.parse(
                        url: capturedURL, bookId: capturedBookId
                    )
                }.value
                if !fallback.chapters.isEmpty {
                    parsed = fallback
                }
            }

            if accessing { fileURL.stopAccessingSecurityScopedResource() }

            if let parsed, !parsed.chapters.isEmpty {
                self.fulltext = parsed
                self.phase = .ready
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(parsed, bookId: book.id)
                }
            } else {
                phase = .unreadable(fileURL)
                return
            }
        }

        // 4. Reader is on screen. Kick off audio generation in the
        // background immediately so audio is buffered by the time the
        // user taps play. The reader is already visible; the banner
        // shows "Generating audio…" while synthesis runs.
        let chapterKey = self.fulltext?.jobId ?? book.id
        let savedChapter = settings.savedChapterIndex(for: chapterKey)
        startAudioBootstrap(startChapterIndex: max(0, savedChapter))
    }

    /// Owns the audio bootstrap — reattach to an existing job, or
    /// submit a new conversion. Updates `statusBanner` so the reader
    /// can surface progress without remounting. Idempotent: cancels
    /// any in-flight task before starting a new one.
    ///
    /// Decision tree:
    /// 1. iOS + `useEmbeddedRuntime` + no backend URL → call
    ///    `PythonBridge.convertChapterStreaming` in-process; segments
    ///    land in `globalPlayer.enqueueSegment` — first audio ≤ 500 ms.
    /// 2. Otherwise → wait for the backend client and use the SSE path.
    ///
    /// - Parameter startChapterIndex: Zero-based chapter to start from.
    ///   Passed by `InstantReaderView.onRequestPlay` so "Play from here"
    ///   begins TTS at the chapter the user is reading, not always ch 0.
    @MainActor
    private func startAudioBootstrap(startChapterIndex: Int = 0) {
        audioBootstrapTask?.cancel()
        statusBanner = "Generating audio…"
        conversionStalled = false
        globalPlayer.isConverting = true
        globalPlayer.conversionStatus.beginSession()
        playerLog.debug("[AudioBootstrap] startAudioBootstrap ch=\(startChapterIndex) — useEmbeddedRuntime=\(settings.useEmbeddedRuntime) hasClient=\(self.client != nil)")

        // Resilience: spin up a watchdog so a silent pipeline (network
        // wedge, hung Edge socket, Python deadlock) is caught instead
        // of leaving the user staring at a forever spinner. 90 s of
        // silence ⇒ cancel + retry; after two consecutive silent
        // stalls we expose a manual retry CTA.
        watchdog?.stop()
        let wd = ConversionWatchdog()
        wd.onStall = {
            playerLog.warning("[Watchdog] stall detected — cancelling and retrying")
            audioBootstrapTask?.cancel()
            startAudioBootstrap(startChapterIndex: startChapterIndex)
        }
        wd.onGaveUp = {
            playerLog.error("[Watchdog] consecutive stalls; surfacing retry CTA")
            audioBootstrapTask?.cancel()
            globalPlayer.isConverting = false
            conversionStalled = true
            statusBanner = "Audio generation stalled. Tap retry."
        }
        wd.start()
        watchdog = wd

        NowPlayingView.setCurrentlyPlaying(bookID: book.id, chapterIndex: startChapterIndex)

        if settings.useEmbeddedRuntime {
            playerLog.debug("[AudioBootstrap] embedded path selected (hasClient=\(self.client != nil))")
            audioBootstrapTask = Task(priority: .utility) {
                await self.bootstrapEmbedded(chapterIndex: startChapterIndex)
            }
            return
        }

        audioBootstrapTask = Task {
            await self.waitForBackendThenBootstrap()
        }
    }

    // MARK: - Embedded TTS path (iOS, no backend)

    /// Drives in-process TTS via `PythonBridge.convertChapterStreaming`
    /// when no backend is available.  Synthesises the chapter at
    /// `chapterIndex` first (fast feedback), then continues with
    /// subsequent chapters in order.
    ///
    /// Each MP3 segment is pushed to `globalPlayer.enqueueSegment` on the
    /// main actor — first audio lands within ~500 ms, satisfying HIG
    /// time-to-first-byte. The per-chapter output MP3 is written to the
    /// app's cache directory so subsequent opens reuse it.
    private func bootstrapEmbedded(chapterIndex startIndex: Int) async {
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded starting at chapter \(startIndex)")

        await MainActor.run {
            globalPlayer.coverArtData = book.coverPNG
        }

        guard let fulltext else {
            await MainActor.run {
                self.statusBanner = "No text available for audio generation."
                self.globalPlayer.isConverting = false
            }
            playerLog.error("[AudioBootstrap] bootstrapEmbedded — fulltext is nil, aborting")
            return
        }

        let chapters = fulltext.chapters
        guard !chapters.isEmpty else {
            await MainActor.run {
                self.statusBanner = "No chapters to convert."
                self.globalPlayer.isConverting = false
            }
            return
        }

        await MainActor.run {
            let chapterProgress = chapters.map { ch in
                JobSnapshot.Chapter(
                    index: ch.index,
                    name: ch.displayTitle,
                    status: nil,
                    downloadUrl: nil,
                    chars: ch.charCount,
                    charsProcessed: nil,
                    progressRatio: nil,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            }
            let snap = JobSnapshot(
                jobId: book.id,
                state: "converting",
                bookTitle: fulltext.bookTitle ?? book.resolvedTitle,
                bookAuthor: fulltext.bookAuthor ?? book.author,
                coverUrl: nil, coverMimeType: nil,
                engine: "edge", voice: nil, language: nil,
                progressPercent: nil,
                chaptersTotal: chapters.count,
                chaptersCompleted: 0,
                chapterProgress: chapterProgress,
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
            )
            globalPlayer.setSnapshot(snap)
        }

        // Per-book output directory inside the app's Caches folder so
        // the OS can evict it under storage pressure without data loss.
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts/\(book.id)", isDirectory: true)

        let voice: String = {
            let sample = chapters
                .filter { $0.text.count > 50 }
                .prefix(5)
                .map { String($0.text.prefix(2000)) }
                .joined(separator: " ")
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            let lang = recognizer.dominantLanguage
            switch lang {
            case .portuguese:            return "pt-BR-FranciscaNeural"
            case .spanish:               return "es-MX-DaliaNeural"
            case .french:                return "fr-FR-DeniseNeural"
            case .german:                return "de-DE-KatjaNeural"
            case .italian:               return "it-IT-ElsaNeural"
            case .japanese:              return "ja-JP-NanamiNeural"
            case .korean:                return "ko-KR-SunHiNeural"
            case .simplifiedChinese:     return "zh-CN-XiaoxiaoNeural"
            case .traditionalChinese:    return "zh-TW-HsiaoChenNeural"
            default:                     return "en-US-AriaNeural"
            }
        }()

        // Process from startIndex, then wrap to cover earlier chapters.
        let safeStart = max(0, min(startIndex, chapters.count - 1))
        let indices: [Int] = Array(safeStart..<chapters.count) + Array(0..<safeStart)
        var chaptersDone = 0
        // Bail out fast on systemic failure (e.g. Python module not found
        // in the bundle): N consecutive identical errors means every
        // chapter will hit the same wall — better to surface one banner
        // than to spam the main actor with hundreds of error records,
        // which froze the UI in the field.
        var consecutiveFailures = 0
        var lastFailureKey: String? = nil
        let maxConsecutiveFailures = 3

        for chapterArrayIndex in indices {
            if Task.isCancelled { break }

            // Use the EbookFulltext chapter that corresponds to this index.
            // EbookFulltext.chapters is 0-based in the array but the `index`
            // property is 1-based (matches backend convention). We address by
            // position in the array, not by `.index`.
            let chapter = chapters[chapterArrayIndex]
            let chapterText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip trash chapters: anything below ~10 chars is residual
            // navigation markup ("1", "I", a stray bullet) that the
            // EPUB fallback parser couldn't strip but isn't worth a
            // round-trip through Python TTS. The previous threshold
            // of `isEmpty` let through "2-char chapters" which then
            // bombarded the embedded interpreter with thousands of
            // imports and crashed in `_PyObject_Malloc`.
            guard chapterText.count >= 10 else {
                playerLog.debug("[AudioBootstrap] skipping trash chapter \(chapterArrayIndex) (\(chapterText.count) chars)")
                chaptersDone += 1
                continue
            }

            let totalChapters = chapters.count
            await MainActor.run {
                self.statusBanner = "Generating audio · \(chaptersDone)/\(totalChapters) ready"
                self.globalPlayer.conversionStatus.setCurrentChapter(
                    index: chapterArrayIndex,
                    name: chapter.displayTitle
                )
                self.globalPlayer.conversionStatus.record(
                    .info,
                    "Starting chapter \(chapterArrayIndex + 1)/\(totalChapters): \(chapter.displayTitle)"
                )
            }
            playerLog.debug("[AudioBootstrap] synthesising chapter \(chapterArrayIndex) (\(chapterText.count) chars)")

            do {
                #if os(iOS)
                _ = try await PythonBridge.shared.convertChapterStreaming(
                    text: chapterText,
                    voice: voice,
                    outputDir: cacheRoot,
                    chapterIndex: chapterArrayIndex
                ) { [weak globalPlayer] segData, chapIdx, segIdx in
                    playerLog.debug("[AudioBootstrap] segment \(segIdx) ch=\(chapIdx) bytes=\(segData.count)")
                    globalPlayer?.enqueueSegment(
                        data: segData,
                        chapterIndex: chapIdx,
                        segmentIndex: segIdx
                    )
                    watchdog?.heartbeat()
                }
                chaptersDone += 1
                consecutiveFailures = 0
                lastFailureKey = nil
                watchdog?.heartbeat()
                playerLog.debug("[AudioBootstrap] chapter \(chapterArrayIndex) complete")
                #else
                try await Self.synthesizeDirectEdge(
                    text: chapterText,
                    voice: voice,
                    cacheRoot: cacheRoot,
                    chapterIndex: chapterArrayIndex,
                    globalPlayer: globalPlayer,
                    watchdog: watchdog
                )
                chaptersDone += 1
                consecutiveFailures = 0
                lastFailureKey = nil
                watchdog?.heartbeat()
                #endif
            } catch {
                playerLog.error("[AudioBootstrap] TTS failed ch \(chapterArrayIndex): \(error.localizedDescription) — trying direct EdgeTTS")
                do {
                    try await Self.synthesizeDirectEdge(
                        text: chapterText,
                        voice: voice,
                        cacheRoot: cacheRoot,
                        chapterIndex: chapterArrayIndex,
                        globalPlayer: globalPlayer,
                        watchdog: watchdog
                    )
                    chaptersDone += 1
                    consecutiveFailures = 0
                    lastFailureKey = nil
                    watchdog?.heartbeat()
                    playerLog.debug("[AudioBootstrap] chapter \(chapterArrayIndex) complete (direct)")
                } catch {
                    let message = error.localizedDescription
                    playerLog.error("[AudioBootstrap] chapter \(chapterArrayIndex) failed: \(message)")
                    let key = message.split(separator: "\n").first.map(String.init) ?? message
                    if key == lastFailureKey {
                        consecutiveFailures += 1
                    } else {
                        consecutiveFailures = 1
                        lastFailureKey = key
                    }
                    await MainActor.run {
                        self.globalPlayer.recordConversionError(
                            "Chapter \(chapterArrayIndex + 1) failed: \(message)"
                        )
                    }
                    if consecutiveFailures >= maxConsecutiveFailures {
                        playerLog.error("[AudioBootstrap] aborting after \(consecutiveFailures) consecutive identical failures: \(key)")
                        await MainActor.run {
                            self.statusBanner = "Audio generation failed: \(key)"
                        }
                        break
                    }
                }
            }
        }

        await MainActor.run {
            self.globalPlayer.isConverting = false
            self.globalPlayer.conversionStatus.endSession()
            if chaptersDone == 0 {
                self.statusBanner = self.statusBanner ?? "Audio generation failed"
            } else {
                self.statusBanner = nil
            }
            self.watchdog?.stop()
        }
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded finished, \(chaptersDone)/\(chapters.count) chapters done")
    }

    // MARK: - Direct EdgeTTS fallback (no Python)

    private static func synthesizeDirectEdge(
        text: String,
        voice: String,
        cacheRoot: URL,
        chapterIndex: Int,
        globalPlayer: AudioPlayer,
        watchdog: ConversionWatchdog?
    ) async throws {
        let normalized = EbookFulltext.Chapter.collapseHardWraps(text)
        let sentences = Self.splitForTTS(normalized, chapterIndex: chapterIndex)

        guard !sentences.isEmpty else { throw PythonBridgeError.emptyResult }

        var totalAudio = Data()
        for (segIdx, sentence) in sentences.enumerated() {
            let bridge = EdgeTTSBridge()
            let timeout = max(15.0, Double(sentence.text.count) / 100.0)
            let mp3 = try await withTimeout(seconds: timeout, label: "Edge sentence \(segIdx)") {
                try await bridge.synthesize(text: sentence.text, voice: voice)
            }
            totalAudio.append(mp3)
            let capturedChapter = chapterIndex
            let capturedSeg = segIdx
            let capturedId = sentence.id
            await MainActor.run {
                globalPlayer.enqueueSegment(
                    data: mp3,
                    chapterIndex: capturedChapter,
                    segmentIndex: capturedSeg,
                    sentenceId: capturedId
                )
            }
            watchdog?.heartbeat()
        }

        if totalAudio.isEmpty {
            throw PythonBridgeError.emptyResult
        }
        let outURL = cacheRoot.appendingPathComponent("direct_ch\(chapterIndex).mp3")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try totalAudio.write(to: outURL)
    }

    /// Split text into TTS-friendly sentences. Batches tiny fragments
    /// (< 40 chars) with the next sentence to avoid excessive WebSocket
    /// connections while keeping sentence-level highlight granularity.
    private static func splitForTTS(_ text: String, chapterIndex: Int) -> [SentenceSpan] {
        let chapter = EbookFulltext.Chapter(
            index: chapterIndex, name: nil, text: text,
            html: nil, css: nil, charCount: text.count, segments: nil
        )
        let raw = chapter.splitSentences()
        var batched: [SentenceSpan] = []
        var pendingText = ""
        var pendingId = ""
        var pendingStart = 0
        for span in raw {
            if pendingText.isEmpty {
                pendingText = span.text
                pendingId = span.id
                pendingStart = span.startChar
            } else {
                pendingText += " " + span.text
            }
            if pendingText.count >= 40 {
                batched.append(SentenceSpan(
                    id: pendingId, text: pendingText,
                    startChar: pendingStart, endChar: span.endChar
                ))
                pendingText = ""
            }
        }
        if !pendingText.isEmpty {
            let endChar = raw.last?.endChar ?? text.count
            batched.append(SentenceSpan(
                id: pendingId, text: pendingText,
                startChar: pendingStart, endChar: endChar
            ))
        }
        return batched
    }

    /// Polls until either a `client` is available (sidecar ready or
    /// remote URL configured) or the user has waited 2 minutes —
    /// whichever comes first. The Python sidecar takes ~20–30 s of
    /// cold start the very first time the app launches, so we can't
    /// just give up immediately.
    private func waitForBackendThenBootstrap() async {
        var waited: TimeInterval = 0
        while !Task.isCancelled, waited < 120 {
            if let client = await MainActor.run(body: { self.client }) {
                await MainActor.run { self.statusBanner = "Generating audio…" }
                await bootstrapAudio(client: client)
                return
            }
            await MainActor.run {
                self.statusBanner = waited < 5
                    ? "Starting audio engine…"
                    : "Starting audio engine — first launch takes ~30 s…"
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            waited += 0.8
        }
        await MainActor.run {
            // Reader stays usable; this banner only surfaces the
            // (optional) audio path. Wording avoids implying the reader
            // depends on the backend — it does not.
            self.statusBanner = "Audio engine is still warming up. Try again in a moment."
        }
    }

    private func bootstrapAudio(client: APIClient) async {
        // Reattach if we have a known job.
        if let existing = book.lastJobId {
            if let snap = try? await client.fetchJob(id: existing) {
                await MainActor.run {
                    self.jobSnapshot = snap
                    let playable = snap.playableChapters
                    self.hasAudio = !playable.isEmpty
                    if !playable.isEmpty { self.globalPlayer.markFirstChapterReady() }
                    if let total = snap.chaptersTotal, total > 0 {
                        let done = snap.chaptersCompleted ?? playable.count
                        self.globalPlayer.conversionProgress = Double(done) / Double(total)
                    }
                    if snap.isTerminal { self.globalPlayer.isConverting = false }
                    self.statusBanner = self.bannerFor(snap)
                }
                subscribeToStream(client: client, jobId: existing)
                return
            }
            // Stale id — fall through and start fresh.
        }

        // Submit a new conversion.
        let fileURL: URL
        do {
            fileURL = try await MainActor.run { try library.openBookFile(id: book.id) }
        } catch {
            await MainActor.run {
                self.statusBanner = "Audio unavailable: \(error.localizedDescription)"
                // Reset state so the global mini-player doesn't keep
                // showing a spinner against a job that will never run.
                self.globalPlayer.isConverting = false
                self.watchdog?.stop()
                self.conversionStalled = true
            }
            return
        }

        var opts = APIClient.ConvertOptions()
        opts.engine = "edge"
        opts.maxPerformance = true
        do {
            let scopeStarted = fileURL.startAccessingSecurityScopedResource()
            let epubData: Data
            do {
                epubData = try Data(contentsOf: fileURL)
            } catch {
                if scopeStarted { fileURL.stopAccessingSecurityScopedResource() }
                throw error
            }
            if scopeStarted { fileURL.stopAccessingSecurityScopedResource() }
            let response = try await client.submitConversion(
                uploadedFile: (epubData, fileURL.lastPathComponent),
                options: opts
            )
            await MainActor.run {
                var updated = self.book
                updated.lastJobId = response.jobId
                updated.lastOpenedAt = Date()
                self.library.update(updated)
            }
            // Pull the first snapshot, then subscribe.
            if let snap = try? await client.fetchJob(id: response.jobId) {
                await MainActor.run {
                    self.jobSnapshot = snap
                    let playable = snap.playableChapters
                    self.hasAudio = !playable.isEmpty
                    if !playable.isEmpty { self.globalPlayer.markFirstChapterReady() }
                    if let total = snap.chaptersTotal, total > 0 {
                        let done = snap.chaptersCompleted ?? playable.count
                        self.globalPlayer.conversionProgress = Double(done) / Double(total)
                    }
                    self.statusBanner = self.bannerFor(snap)
                }
            }
            subscribeToStream(client: client, jobId: response.jobId)
        } catch {
            await MainActor.run {
                self.statusBanner = "Audio failed: \(error.localizedDescription)"
                self.globalPlayer.isConverting = false
                self.watchdog?.stop()
                self.conversionStalled = true
            }
        }
    }

    private func subscribeToStream(client: APIClient, jobId: String) {
        streamTask?.cancel()
        streamTask = Task { @MainActor in
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
                    // Any event — keepalive, snapshot, or error frame —
                    // counts as a sign of life and resets the stall
                    // clock. We do this before decoding so a "stuck on
                    // decoding" loop doesn't starve the watchdog.
                    self.watchdog?.heartbeat()
                    if let updated = APIClient.decodeSnapshot(from: event.rawPayload) {
                        self.jobSnapshot = updated
                        let playable = updated.playableChapters
                        self.hasAudio = !playable.isEmpty

                        // Keep global player conversion state in sync so
                        // MiniPlayerBar renders the correct indicator.
                        if !playable.isEmpty {
                            self.globalPlayer.markFirstChapterReady()
                        }
                        if let total = updated.chaptersTotal, total > 0 {
                            let done = updated.chaptersCompleted ?? playable.count
                            self.globalPlayer.conversionProgress = Double(done) / Double(total)
                        }
                        self.statusBanner = self.bannerFor(updated)

                        if updated.isTerminal {
                            self.globalPlayer.isConverting = false
                            self.statusBanner = nil
                            self.watchdog?.stop()
                            break
                        }
                    }
                }
            } catch {
                // Any failure here means the user is staring at a
                // dead stream. Guarantee state reset so the UI
                // never wedges in "isConverting=true" — that's the
                // exact silent-stall bug this slice targets.
                self.globalPlayer.isConverting = false
                self.globalPlayer.recordConversionError("Stream error: \(error.localizedDescription)")
                self.globalPlayer.conversionStatus.endSession()
                self.statusBanner = "Stream interrupted. Tap retry."
                self.conversionStalled = true
                self.watchdog?.stop()
            }
        }
    }

    private func bannerFor(_ snap: JobSnapshot) -> String? {
        if snap.isTerminal { return nil }
        let done = snap.chaptersCompleted ?? snap.playableChapters.count
        let total = snap.chaptersTotal ?? 0
        if total > 0 {
            return "Generating audio · \(done)/\(total) chapters ready"
        }
        return "Generating audio…"
    }

    // MARK: - Error / re-pick UI

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityLabel("Error")
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                if needsRePick(message: message) {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Locate file…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Retry") { Task { await openFlow() } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func needsRePick(message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("re-import")
            || m.contains("security-scoped")
            || m.contains("couldn't be opened")
    }

    private func handleRePick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let picked = urls.first else { return }
        do {
            _ = try library.importBook(from: picked)
            Task { await openFlow() }
        } catch {
            phase = .error("Re-import failed: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
#Preview("BookOpen — preview-3") {
    CompatNavigationStack {
        BookOpenView(book: BookEntity(
            id: "preview-3",
            title: "O Hobbit",
            author: "J.R.R. Tolkien",
            bookmark: Data(),
            displayFilename: "o_hobbit.epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil,
            cachedOffline: false
        ))
    }
    .environmentObject(AppSettings())
    .environmentObject(LibraryStore.previewPopulated)
    .environmentObject(AudioPlayer())
}
#endif
