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
    let onClose: (() -> Void)?

    init(book: BookEntity, onClose: (() -> Void)? = nil) {
        self.book = book
        self.onClose = onClose
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    /// Global audio player — receives conversion state (`isConverting`,
    /// `conversionProgress`, `firstChapterReady`) so `MiniPlayerBar`
    /// can show the spinner / conversion progress without requiring a
    /// loaded audio item.
    @EnvironmentObject private var globalPlayer: AudioPlayer
    @EnvironmentObject private var audioWarmup: AudioEngineWarmup

    @State private var phase: Phase = .resolving
    @State private var fulltext: EbookFulltext?
    @State private var detectedEpubLanguage: String?
    @State private var jobSnapshot: JobSnapshot?
    @State private var statusBanner: String?       // top-of-screen "Generating audio…" hint
    @State private var hasAudio: Bool = false
    @State private var audioBootstrapTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?
    /// JobId currently being SSE-streamed. Short-circuits re-subscription
    /// when `subscribeToStream` is called again for the same job
    /// (state restoration, deep link, watchdog retry after a transient
    /// disconnect) — re-opening the same connection tears down a
    /// working backend pipe for no behavioural benefit.
    @State private var streamingJobId: String?
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
    @State private var pdfChromeVisible = true
    @State private var registeredFontURLs: [URL] = []
    /// Manages per-chapter audio cache and prefetch.
    @State private var chapterCacheManager: ChapterCacheManager?

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
                ProgressView(L10n.string("bookOpen.opening", book.resolvedTitle))
                    .controlSize(.large)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                // PDFs render via PDFView (HIG / Apple Books pattern).
                // The reflow `InstantReaderView` is for EPUB only;
                // forcing PDFs through it would strip layout, images,
                // and break the user's mental model of "a PDF page".
                if book.fileType == .pdf, let pdf = pdfDocument {
                    PdfReaderView(
                        document: pdf,
                        currentPageIndex: $pdfPageIndex,
                        onPageTap: { withAnimation(.easeInOut(duration: 0.25)) { pdfChromeVisible.toggle() } }
                    )
                } else if let fulltext {
                    if let cacheManager = chapterCacheManager {
                        InstantReaderView(
                            fulltext: fulltext,
                            snapshot: $jobSnapshot,
                            statusBanner: statusBanner,
                            hasAudio: hasAudio,
                            backendBaseURL: settings.useEmbeddedRuntime ? nil : settings.resolvedBaseURL,
                            coverPNG: book.coverPNG,
                            onRequestAudioRetry: { startAudioBootstrap() },
                            // `rebuildSegmentQueue: true` — the InstantReaderView's
                            // play-menu is a deliberate "restart at this chapter"
                            // gesture (From beginning / From current chapter). In
                            // embedded mode the existing AVQueuePlayer is torn down
                            // and the bootstrap arms auto-play so the user hears
                            // audio without a second tap.
                            onRequestPlay: { chapterIdx, _ in
                                startAudioBootstrap(startChapterIndex: chapterIdx, rebuildSegmentQueue: true)
                            },
                            onClose: onClose,
                            cacheManager: cacheManager
                        )
                        .environment(\.epubFontDirectory, registeredFontURLs.first?.deletingLastPathComponent())
                    } else {
                        ProgressView("Preparing…")
                            .onAppear { ensureCacheManager() }
                    }
                } else {
                    // HIG empty-state: title + description + system
                    // illustration, centred. Uses `ContentUnavailableView`
                    // on iOS 17+ for the native treatment; falls back to
                    // a hand-laid VStack on iOS 15/16.
                    EmptyContentView(
                        title: L10n.string("bookOpen.noContent"),
                        message: L10n.string("bookOpen.noContentDescription"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }

            case .unreadable(let fileURL):
                LocalEpubReaderView(fileURL: fileURL, book: book)

            case .error(let msg):
                errorView(message: msg)
            }
        }
        .navigationTitle("")
        .compatReaderBackButtonHidden()
        .compatInlineNavigationTitle()
        .modifier(PdfChromeVisibilityModifier(visible: book.fileType == .pdf ? pdfChromeVisible : false))
        // BookOpenView is pushed from Library and owns its own in-reader
        // playback chrome. Keep the root mini player hidden for the whole
        // open-book detail so immersive reader mode has no stray global UI.
        .readerChromeVisible(false)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if let onClose, book.fileType == .pdf {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("player.close"))
                }
            }
        }
        .task { await openFlow() }
        .onAppear {
            CacheActivityRegistry.begin(jobId: book.id)
        }
        .onDisappear {
            // If a conversion was running when the user left, end the Live
            // Activity so it doesn't linger indefinitely on the lock screen.
            if globalPlayer.isConverting {
                WidgetDataSync.endConversionActivity(bookId: book.id, failed: true)
            }
            audioBootstrapTask?.cancel()
            streamTask?.cancel()
            streamingJobId = nil
            watchdog?.stop()
            chapterCacheManager?.cancelAll()
            watchdog = nil
            globalPlayer.clearConversionState()
            CacheActivityRegistry.end(jobId: book.id)
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
            if let metadata = try? EpubMetadataReader.readMetadata(from: fileURL) {
                detectedEpubLanguage = metadata.language
            }
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
            ensureCacheManager()
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
                ensureCacheManager()
                self.phase = .ready
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(parsed, bookId: book.id)
                }
            } else {
                phase = .unreadable(fileURL)
                return
            }
        }

        // Audio conversion is strictly user-initiated. Opening a book only
        // prepares text, fonts, and the local cache; the Reader's Play button
        // or an explicit "play from here/chapter" action calls
        // `startAudioBootstrap(...)`.
        ensureCacheManager()
        let chapterKey = self.fulltext?.jobId ?? book.id
        let savedChapter = settings.savedChapterIndex(for: chapterKey)
        WidgetDataSync.updateLastRead(
            bookId: book.id,
            chapterIndex: max(0, savedChapter),
            totalChapters: fulltext?.chapters.count
        )
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
    private func startAudioBootstrap(startChapterIndex: Int = 0, rebuildSegmentQueue: Bool = false) {
        audioBootstrapTask?.cancel()
        // When the caller intends a fresh queue (user tapped
        // "from the beginning" / "previous chapter" while a segment
        // queue is alive), tear it down and arm `pendingAutoPlay` so
        // the new bootstrap's first `enqueueSegment` flips the player
        // to rate.rawValue without a second user tap.
        if rebuildSegmentQueue, settings.useEmbeddedRuntime {
            let resumePosition = globalPlayer.consumePersistedResumePosition(for: book.id)
            globalPlayer.prepareSegmentRestart(resumePosition: resumePosition)
        }
        statusBanner = "Generating audio…"
        conversionStalled = false
        globalPlayer.isConverting = true
        globalPlayer.conversionStatus.beginSession()
        playerLog.debug("[AudioBootstrap] startAudioBootstrap ch=\(startChapterIndex) rebuildQueue=\(rebuildSegmentQueue) — useEmbeddedRuntime=\(settings.useEmbeddedRuntime) hasClient=\(self.client != nil)")

        // Start Live Activity for this conversion. startConversionActivity is
        // guarded internally by #if canImport(ActivityKit) && os(iOS) so the
        // call is safe on macOS too — it compiles but is a no-op at runtime.
        let totalChapters = fulltext?.chapters.count ?? 0
        WidgetDataSync.startConversionActivity(
            bookTitle: fulltext?.bookTitle ?? book.resolvedTitle,
            bookId: book.id,
            chaptersTotal: totalChapters
        )

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
                if await self.audioWarmup.start() {
                    guard await self.audioWarmup.waitUntilReady() else {
                        await MainActor.run {
                            self.statusBanner = self.audioWarmup.message.isEmpty
                                ? L10n.string("audioWarmup.retry")
                                : self.audioWarmup.message
                            self.globalPlayer.isConverting = false
                        }
                        return
                    }
                    await self.bootstrapEmbedded(chapterIndex: startChapterIndex)
                } else {
                    await MainActor.run {
                        self.statusBanner = self.audioWarmup.message.isEmpty
                            ? L10n.string("audioWarmup.retry")
                            : self.audioWarmup.message
                        self.globalPlayer.isConverting = false
                    }
                }
            }
            return
        }

        audioBootstrapTask = Task {
            await self.waitForBackendThenBootstrap(startChapterIndex: startChapterIndex)
        }
    }

    // MARK: - Embedded TTS path (iOS, no backend)

    /// Maximum concurrent chapter synthesis tasks for the direct Edge path.
    /// Each task opens its own WebSocket connections per sentence, so 3 is
    /// a good balance between throughput and connection pressure.
    private static let parallelChapterLimit = 3

    /// Drives in-process TTS via `PythonBridge.convertChapterStreaming`
    /// when no backend is available.  Synthesises the chapter at
    /// `chapterIndex` first (fast feedback), then continues with
    /// subsequent chapters in parallel (direct Edge, macOS) or sequentially
    /// (direct Edge on iOS to avoid blocking the UI on Python bootstrap).
    ///
    /// Each MP3 segment is pushed to `globalPlayer.enqueueSegment` on the
    /// main actor — first audio lands within ~500 ms, satisfying HIG
    /// time-to-first-byte.
    ///
    /// Optimization layers:
    /// 1. Content-addressed disk cache — reopening a book is instant.
    /// 2. First chapter processed alone for fast time-to-first-audio.
    /// 3. macOS: remaining chapters synthesized 3-at-a-time via TaskGroup,
    ///    with an ordering gate to ensure in-order enqueue.
    /// 4. iOS: sequential (Python GIL constraint) but cache-first.
    private func bootstrapEmbedded(chapterIndex startIndex: Int) async {
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded starting at chapter \(startIndex)")

        await MainActor.run {
            globalPlayer.coverArtData = book.coverPNG
            // Wire the restart hook so `previousChapter()` (transport
            // bar) and "From the beginning" (play menu) can leave the
            // current segment queue and rebuild from a different
            // starting chapter. Captures `[weak audioPlayer]` analogue
            // via the @State closure indirection — `startAudioBootstrap`
            // is a method on `self`, the View struct value-captures
            // safely.
            globalPlayer.restartSegmentQueueHandler = { target in
                self.startAudioBootstrap(startChapterIndex: target, rebuildSegmentQueue: true)
            }
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
                engine: "edge", voice: nil, language: detectedEpubLanguage,
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
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let voice: String = {
            let sample = chapters
                .filter { $0.text.count > 50 }
                .prefix(5)
                .map { String($0.text.prefix(2000)) }
                .joined(separator: " ")
            return VoiceSelector.edgeVoice(for: sample, declaredLanguage: detectedEpubLanguage)
        }()

        // Process from startIndex, then wrap to cover earlier chapters.
        let safeStart = max(0, min(startIndex, chapters.count - 1))
        let indices: [Int] = Array(safeStart..<chapters.count) + Array(0..<safeStart)

        // Pre-filter work items and compute cache paths upfront.
        struct ChapterWorkItem {
            let arrayIndex: Int
            let text: String
            let title: String
            let cacheFile: URL
        }
        var workItems: [ChapterWorkItem] = []
        for idx in indices {
            let chapter = chapters[idx]
            let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 10 else {
                playerLog.debug("[AudioBootstrap] skipping trash chapter \(idx) (\(text.count) chars)")
                continue
            }
            let cacheFile = cacheRoot.appendingPathComponent("chapter_\(idx).mp3")
            workItems.append(ChapterWorkItem(
                arrayIndex: idx, text: text, title: chapter.displayTitle, cacheFile: cacheFile
            ))
        }

        let totalChapters = chapters.count
        var chaptersDone = 0
        var consecutiveFailures = 0
        var lastFailureKey: String? = nil
        let maxConsecutiveFailures = 3

        // --- Phase 1: First chapter alone for fast time-to-first-audio ---
        if let first = workItems.first {
            let result = await self.synthesizeOneChapter(
                arrayIndex: first.arrayIndex, text: first.text,
                title: first.title, cacheFile: first.cacheFile,
                voice: voice, cacheRoot: cacheRoot,
                totalChapters: totalChapters, chaptersDone: chaptersDone
            )
            switch result {
            case .success:
                chaptersDone += 1
                consecutiveFailures = 0
                lastFailureKey = nil
                let done1 = chaptersDone
                let capturedTitle1 = fulltext.bookTitle ?? book.resolvedTitle
                let capturedChName1 = first.title
                await MainActor.run {
                    WidgetDataSync.updateConversionProgress(
                        bookTitle: capturedTitle1,
                        chaptersDone: done1,
                        chaptersTotal: totalChapters,
                        currentChapterName: capturedChName1
                    )
                }
            case .failure(let key):
                consecutiveFailures += 1
                lastFailureKey = key
            }
        }

        guard consecutiveFailures < maxConsecutiveFailures, !Task.isCancelled else {
            await finishEmbeddedBootstrap(chaptersDone: chaptersDone, totalChapters: totalChapters)
            return
        }

        // --- Phase 2: Remaining chapters ---
        let remaining = Array(workItems.dropFirst())

        #if os(iOS)
        // iOS uses direct Edge sequentially so audio does not wait on
        // Python bootstrap/GIL. Cache hits are still instant.
        // Cache hits are still instant.
        for work in remaining {
            if Task.isCancelled { break }
            if consecutiveFailures >= maxConsecutiveFailures { break }

            let result = await self.synthesizeOneChapter(
                arrayIndex: work.arrayIndex, text: work.text,
                title: work.title, cacheFile: work.cacheFile,
                voice: voice, cacheRoot: cacheRoot,
                totalChapters: totalChapters, chaptersDone: chaptersDone
            )
            switch result {
            case .success:
                chaptersDone += 1
                consecutiveFailures = 0
                lastFailureKey = nil
                let doneSeq = chaptersDone
                let capturedTitleSeq = fulltext.bookTitle ?? book.resolvedTitle
                let capturedChNameSeq = work.title
                await MainActor.run {
                    WidgetDataSync.updateConversionProgress(
                        bookTitle: capturedTitleSeq,
                        chaptersDone: doneSeq,
                        chaptersTotal: totalChapters,
                        currentChapterName: capturedChNameSeq
                    )
                }
            case .failure(let key):
                if key == lastFailureKey {
                    consecutiveFailures += 1
                } else {
                    consecutiveFailures = 1
                    lastFailureKey = key
                }
                await MainActor.run {
                    self.globalPlayer.recordConversionError(
                        "Chapter \(work.arrayIndex + 1) failed: \(key)"
                    )
                }
            }
        }
        #else
        // macOS direct Edge path: synthesize up to 3 chapters concurrently.
        // Results are collected and enqueued in original order so the
        // AVQueuePlayer receives chapters sequentially.
        let batchSize = Self.parallelChapterLimit
        var batchStart = 0

        while batchStart < remaining.count, !Task.isCancelled,
              consecutiveFailures < maxConsecutiveFailures {
            let batchEnd = min(batchStart + batchSize, remaining.count)
            let batch = Array(remaining[batchStart..<batchEnd])

            // Launch parallel synthesis for this batch.
            let results: [(ChapterWorkItem, Result<Data, Error>)] = await withTaskGroup(
                of: (ChapterWorkItem, Result<Data, Error>).self,
                returning: [(ChapterWorkItem, Result<Data, Error>)].self
            ) { group in
                for work in batch {
                    group.addTask {
                        // Cache hit — instant
                        if let cached = Self.loadCachedChapterData(at: work.cacheFile) {
                            return (work, .success(cached))
                        }
                        // Synthesize via direct Edge (Swift WebSocket, no Python)
                        do {
                            let audio = try await Self.synthesizeDirectEdgeRaw(
                                text: work.text, voice: voice,
                                chapterIndex: work.arrayIndex
                            )
                            return (work, .success(audio))
                        } catch {
                            return (work, .failure(error))
                        }
                    }
                }
                var collected: [(ChapterWorkItem, Result<Data, Error>)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            // Sort by original chapter order and enqueue sequentially.
            let sorted = results.sorted { $0.0.arrayIndex < $1.0.arrayIndex }
            for (work, result) in sorted {
                if Task.isCancelled { break }
                switch result {
                case .success(let audio):
                    await MainActor.run {
                        self.statusBanner = "Generating audio · \(chaptersDone)/\(totalChapters) ready"
                        self.globalPlayer.conversionStatus.setCurrentChapter(
                            index: work.arrayIndex, name: work.title
                        )
                    }
                    await MainActor.run {
                        self.globalPlayer.enqueueSegment(
                            data: audio,
                            chapterIndex: work.arrayIndex,
                            segmentIndex: 0
                        )
                    }
                    // Persist to disk cache for next open
                    try? audio.write(to: work.cacheFile)
                    chaptersDone += 1
                    consecutiveFailures = 0
                    lastFailureKey = nil
                    watchdog?.heartbeat()
                    playerLog.debug("[AudioBootstrap] chapter \(work.arrayIndex) complete (parallel)")
                    let donePar = chaptersDone
                    let capturedTitlePar = fulltext.bookTitle ?? book.resolvedTitle
                    let capturedChNamePar = work.title
                    await MainActor.run {
                        WidgetDataSync.updateConversionProgress(
                            bookTitle: capturedTitlePar,
                            chaptersDone: donePar,
                            chaptersTotal: totalChapters,
                            currentChapterName: capturedChNamePar
                        )
                    }

                case .failure(let error):
                    let message = error.localizedDescription
                    playerLog.error("[AudioBootstrap] chapter \(work.arrayIndex) failed: \(message)")
                    let key = message.split(separator: "\n").first.map(String.init) ?? message
                    if key == lastFailureKey {
                        consecutiveFailures += 1
                    } else {
                        consecutiveFailures = 1
                        lastFailureKey = key
                    }
                    await MainActor.run {
                        self.globalPlayer.recordConversionError(
                            "Chapter \(work.arrayIndex + 1) failed: \(message)"
                        )
                    }
                }
            }

            if consecutiveFailures >= maxConsecutiveFailures {
                playerLog.error("[AudioBootstrap] aborting after \(consecutiveFailures) consecutive identical failures")
                await MainActor.run {
                    self.statusBanner = "Audio generation failed: \(lastFailureKey ?? "unknown")"
                }
                break
            }
            batchStart = batchEnd
        }
        #endif

        await finishEmbeddedBootstrap(chaptersDone: chaptersDone, totalChapters: totalChapters)
    }

    // MARK: - Single chapter synthesis (cache-aware)

    private enum ChapterSynthResult {
        case success
        case failure(String)
    }

    /// Synthesize one chapter with cache-hit fast path. Used by both
    /// Phase 1 (first chapter alone) and the iOS sequential Phase 2.
    private func synthesizeOneChapter(
        arrayIndex: Int, text: String, title: String, cacheFile: URL,
        voice: String,
        cacheRoot: URL,
        totalChapters: Int,
        chaptersDone: Int
    ) async -> ChapterSynthResult {
        guard !Task.isCancelled else { return .failure("cancelled") }

        await MainActor.run {
            self.statusBanner = "Generating audio · \(chaptersDone)/\(totalChapters) ready"
            self.globalPlayer.setSegmentChapterEstimate(
                AudioPlayer.estimatedChapterDurationSeconds(
                    wordCount: text.split { $0.isWhitespace }.count
                ),
                forChapterIndex: arrayIndex
            )
            self.globalPlayer.conversionStatus.setCurrentChapter(
                index: arrayIndex, name: title
            )
            self.globalPlayer.conversionStatus.record(
                .info,
                "Starting chapter \(arrayIndex + 1)/\(totalChapters): \(title)"
            )
        }

        // --- Cache hit: enqueue from disk instantly ---
        if let cached = Self.loadCachedChapterData(at: cacheFile) {
            playerLog.debug("[AudioBootstrap] cache hit ch \(arrayIndex) (\(cached.count) bytes)")
            await MainActor.run {
                self.globalPlayer.enqueueSegment(
                    data: cached,
                    chapterIndex: arrayIndex,
                    segmentIndex: 0
                )
            }
            watchdog?.heartbeat()
            return .success
        }

        playerLog.debug("[AudioBootstrap] synthesising chapter \(arrayIndex) (\(text.count) chars)")

        do {
            #if os(iOS)
            try await Self.synthesizeDirectEdge(
                text: text,
                voice: voice,
                cacheRoot: cacheRoot,
                cacheFile: cacheFile,
                chapterIndex: arrayIndex,
                globalPlayer: globalPlayer,
                watchdog: watchdog
            )
            watchdog?.heartbeat()
            playerLog.debug("[AudioBootstrap] chapter \(arrayIndex) complete")
            return .success
            #else
            try await Self.synthesizeDirectEdge(
                text: text,
                voice: voice,
                cacheRoot: cacheRoot,
                cacheFile: cacheFile,
                chapterIndex: arrayIndex,
                globalPlayer: globalPlayer,
                watchdog: watchdog
            )
            watchdog?.heartbeat()
            playerLog.debug("[AudioBootstrap] chapter \(arrayIndex) complete")
            return .success
            #endif
        } catch {
            playerLog.error("[AudioBootstrap] TTS failed ch \(arrayIndex): \(error.localizedDescription) — trying direct EdgeTTS")
            do {
                try await Self.synthesizeDirectEdge(
                    text: text,
                    voice: voice,
                    cacheRoot: cacheRoot,
                    cacheFile: cacheFile,
                    chapterIndex: arrayIndex,
                    globalPlayer: globalPlayer,
                    watchdog: watchdog
                )
                watchdog?.heartbeat()
                playerLog.debug("[AudioBootstrap] chapter \(arrayIndex) complete (direct fallback)")
                return .success
            } catch {
                let message = error.localizedDescription
                playerLog.error("[AudioBootstrap] chapter \(arrayIndex) failed: \(message)")
                let key = message.split(separator: "\n").first.map(String.init) ?? message
                return .failure(key)
            }
        }
    }

    private func finishEmbeddedBootstrap(chaptersDone: Int, totalChapters: Int) async {
        let failed = chaptersDone == 0
        let capturedBookId = book.id
        await MainActor.run {
            self.globalPlayer.isConverting = false
            self.globalPlayer.conversionStatus.endSession()
            if failed {
                self.statusBanner = self.statusBanner ?? "Audio generation failed"
            } else {
                self.statusBanner = nil
            }
            self.watchdog?.stop()
            // End the Live Activity — safe on macOS (no-op at compile time).
            WidgetDataSync.endConversionActivity(bookId: capturedBookId, failed: failed)
        }
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded finished, \(chaptersDone)/\(totalChapters) chapters done")
    }

    // MARK: - Chapter cache utilities

    /// Load a cached chapter MP3 from disk. Returns nil if missing or too small.
    /// Nonisolated so it can be called from TaskGroup child tasks.
    private nonisolated static func loadCachedChapterData(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              data.count > 100 else { return nil }
        return data
    }

    // MARK: - Direct EdgeTTS (no Python)

    /// Synthesize a chapter via direct Edge WebSocket, returning raw MP3
    /// bytes without enqueuing. Used by the parallel batch path on macOS.
    /// Nonisolated so it can run concurrently in TaskGroup children.
    private nonisolated static func synthesizeDirectEdgeRaw(
        text: String, voice: String, chapterIndex: Int
    ) async throws -> Data {
        let normalized = EbookFulltext.Chapter.collapseHardWraps(text)
        let sentences = splitForTTS(normalized, chapterIndex: chapterIndex)
        guard !sentences.isEmpty else { throw PythonBridgeError.emptyResult }

        var totalAudio = Data()
        for (segIdx, sentence) in sentences.enumerated() {
            let bridge = EdgeTTSBridge()
            let timeout = max(15.0, Double(sentence.text.count) / 100.0)
            let mp3 = try await withTimeout(seconds: timeout, label: "Edge sentence \(segIdx)") {
                try await bridge.synthesize(text: sentence.text, voice: voice)
            }
            totalAudio.append(mp3)
        }
        guard !totalAudio.isEmpty else { throw PythonBridgeError.emptyResult }
        return totalAudio
    }

    /// Sequential direct Edge synthesis with per-sentence streaming to the
    /// player. Used for single-chapter paths and as iOS fallback.
    private static func synthesizeDirectEdge(
        text: String,
        voice: String,
        cacheRoot: URL,
        cacheFile: URL,
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
        // Write to content-addressed cache file for instant reuse.
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try totalAudio.write(to: cacheFile)
    }

    /// Split text into TTS-friendly sentences. Batches tiny fragments
    /// (< 40 chars) with the next sentence to avoid excessive WebSocket
    /// connections while keeping sentence-level highlight granularity.
    private nonisolated static func splitForTTS(_ text: String, chapterIndex: Int) -> [SentenceSpan] {
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
    private func waitForBackendThenBootstrap(startChapterIndex: Int) async {
        var waited: TimeInterval = 0
        while !Task.isCancelled, waited < 120 {
            if let client = await MainActor.run(body: { self.client }) {
                await MainActor.run { self.statusBanner = "Generating audio…" }
                await bootstrapAudio(client: client, startChapterIndex: startChapterIndex)
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

    private func bootstrapAudio(client: APIClient, startChapterIndex: Int) async {
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
            let capturedBookIdOpen = book.id
            await MainActor.run {
                self.statusBanner = "Audio unavailable: \(error.localizedDescription)"
                // Reset state so the global mini-player doesn't keep
                // showing a spinner against a job that will never run.
                self.globalPlayer.isConverting = false
                self.watchdog?.stop()
                self.conversionStalled = true
                WidgetDataSync.endConversionActivity(bookId: capturedBookIdOpen, failed: true)
            }
            return
        }

        var opts = APIClient.ConvertOptions()
        opts.engine = "edge"
        opts.maxPerformance = true
        opts.priorityChapterIndex = startChapterIndex
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
            let capturedBookIdBoot = book.id
            await MainActor.run {
                self.statusBanner = "Audio failed: \(error.localizedDescription)"
                self.globalPlayer.isConverting = false
                self.watchdog?.stop()
                self.conversionStalled = true
                WidgetDataSync.endConversionActivity(bookId: capturedBookIdBoot, failed: true)
            }
        }
    }

    private func subscribeToStream(client: APIClient, jobId: String) {
        // Already streaming this jobId? Don't tear down a healthy
        // connection just to rebuild the identical one.
        if streamingJobId == jobId, let existing = streamTask, !existing.isCancelled {
            return
        }
        streamTask?.cancel()
        streamingJobId = jobId
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
                        // Keep the mounted AVQueuePlayer in lockstep with the
                        // SSE snapshot. Without this forwarding, the reader
                        // shows newly completed chapters while the live queue
                        // remains stuck at the chapters present at bootstrap.
                        self.globalPlayer.updateSnapshot(updated)
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
                            // Push progress to the Live Activity every event so the
                            // Dynamic Island progress bar stays current.
                            if !updated.isTerminal {
                                let currentChName = updated.chapterProgress?
                                    .first(where: { $0.status == "converting" })?
                                    .displayTitle
                                WidgetDataSync.updateConversionProgress(
                                    bookTitle: updated.bookTitle ?? self.book.resolvedTitle,
                                    chaptersDone: done,
                                    chaptersTotal: total,
                                    currentChapterName: currentChName
                                )
                            }
                        }
                        self.statusBanner = self.bannerFor(updated)

                        if updated.isTerminal {
                            self.globalPlayer.isConverting = false
                            self.statusBanner = nil
                            self.watchdog?.stop()
                            let termFailed = updated.state.lowercased() == "failed"
                                || updated.state.lowercased() == "cancelled"
                            WidgetDataSync.endConversionActivity(
                                bookId: self.book.id,
                                failed: termFailed
                            )
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
                WidgetDataSync.endConversionActivity(bookId: self.book.id, failed: true)
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

    @ViewBuilder
    private func errorView(message: String) -> some View {
        if #available(iOS 17, macOS 14, *) {
            ContentUnavailableView {
                Label(
                    L10n.string("bookOpen.error"),
                    systemImage: "exclamationmark.triangle.fill"
                )
            } description: {
                Text(message)
            } actions: {
                errorActions(message: message)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L10n.string("bookOpen.error"))
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: 480)
                HStack(spacing: 12) { errorActions(message: message) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func errorActions(message: String) -> some View {
        if needsRePick(message: message) {
            Button {
                showingPicker = true
            } label: {
                Label(L10n.string("bookOpen.locateFile"), systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        Button(L10n.string("bookOpen.retry")) {
            Task { await openFlow() }
        }
        .buttonStyle(.bordered)
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

    // MARK: - Chapter Cache Manager

    /// Creates the `ChapterCacheManager` from the current `fulltext`.
    /// Idempotent — only creates once.
    private func ensureCacheManager() {
        guard chapterCacheManager == nil, let fulltext else { return }
        let sample = fulltext.chapters
            .filter { $0.text.count > 50 }
            .prefix(5)
            .map { String($0.text.prefix(2000)) }
            .joined(separator: " ")
        let voice = VoiceSelector.edgeVoice(for: sample, declaredLanguage: detectedEpubLanguage)
        chapterCacheManager = ChapterCacheManager(
            bookId: book.id,
            chapters: fulltext.chapters,
            voice: voice
        )
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
    .environmentObject(AudioEngineWarmup())
}
#endif

private struct PdfChromeVisibilityModifier: ViewModifier {
    let visible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16, *) {
            content
                .toolbar(visible ? .visible : .hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
        } else {
            content
                .navigationBarHidden(!visible)
                .background(BookOpenTabBarVisibilityController(visible: false))
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
private struct BookOpenTabBarVisibilityController: UIViewControllerRepresentable {
    let visible: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            viewController.tabBarController?.tabBar.isHidden = !visible
        }
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: ()) {
        viewController.tabBarController?.tabBar.isHidden = false
    }
}
#endif
