import SwiftUI
import UniformTypeIdentifiers
import PDFKit
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
    /// Resolved PDF document — set only for `book.fileType == .pdf`
    /// once `openFlow()` has loaded the file. Kept on `BookOpenView`
    /// (not inside `PdfReaderView`) so the same instance survives a
    /// toolbar action like "Listen" without re-opening the file.
    @State private var pdfDocument: PDFDocument?
    @State private var pdfPageIndex: Int = 0

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
                        backendBaseURL: settings.resolvedBaseURL,
                        coverPNG: book.coverPNG,
                        onRequestAudioRetry: { startAudioBootstrap() },
                        onRequestPlay: { chapterIdx, _ in startAudioBootstrap(startChapterIndex: chapterIdx) }
                    )
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
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [.epub, .pdf],
            allowsMultipleSelection: false
        ) { result in
            handleRePick(result)
        }
    }

    // MARK: - Flow

    @MainActor
    private func openFlow() async {
        if isSwiftUIPreview { phase = .ready; return }

        // Reset any stale conversion state from a prior book session.
        globalPlayer.clearConversionState()

        // 1. Resolve the file URL — required for both local parse
        //    and (later) conversion submission. Failures here surface
        //    the re-pick UI.
        let fileURL: URL
        do {
            fileURL = try library.openBookFile(id: book.id)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        // PDF path: PDFKit is fully on-device; no Python parse needed.
        // We still extract pseudo-chapters via `PdfTextExtractor` so
        // the TTS conversion path (when the user taps Listen) has a
        // chapter manifest to feed the engine — but the reader is
        // `PdfReaderView`, not the reflow text view.
        if book.fileType == .pdf {
            guard let doc = PDFDocument(url: fileURL) else {
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
            if let cached = LocalFulltextCache.read(bookId: book.id) {
                self.fulltext = cached
            } else if let extracted = try? PdfTextExtractor.extract(
                from: fileURL, bookId: book.id
            ) {
                self.fulltext = extracted
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(extracted, bookId: book.id)
                }
            }
            self.phase = .ready
            return
        }

        // 2. Try the on-disk fulltext cache first. Even on a fresh
        //    install of a book we built locally during the previous
        //    session, this hits.
        if let cached = LocalFulltextCache.read(bookId: book.id) {
            self.fulltext = cached
            self.phase = .ready
        } else {
            // 3. No cache → parse on-device. On iOS this hops into
            //    the embedded Python interpreter and runs the same
            //    `ebook_reader.parse_epub_to_dict` the backend uses,
            //    so the iOS app and the sidecar/HF server always
            //    agree on chapter boundaries.
            #if os(iOS) || targetEnvironment(simulator)
            // On a real device, `fileURL` is a security-scoped URL
            // resolved from a bookmark. Without `startAccessing…`
            // the file is visible in the directory listing but
            // read(2) / open(2) return EPERM — the sandbox denies
            // access. The simulator runs without the full iOS
            // sandbox, so reads succeed even without the scope,
            // masking this failure in every Simulator run.
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

            // Two-tier parse: prefer the canonical Python pipeline
            // (TOC-aware, hierarchy-preserving) but fall back to a
            // pure-Swift spine-walker when the Python embed is not
            // yet bootstrapped, when an EPUB uses an OPF dialect the
            // canonical parser rejects, or when PythonKit traps.
            // Either path produces an EbookFulltext the reader can
            // render — we only surface "unreadable" if both fail.
            var parsed: EbookFulltext?
            do {
                parsed = try await PythonBridge.shared.parseEpub(
                    at: fileURL, bookId: book.id
                )
            } catch {
                parsed = nil
            }
            if parsed == nil || (parsed?.chapters.isEmpty ?? true) {
                let fallback = EpubFallbackParser.parse(url: fileURL, bookId: book.id)
                if !fallback.chapters.isEmpty {
                    parsed = fallback
                }
            }
            if let parsed, !parsed.chapters.isEmpty {
                self.fulltext = parsed
                self.phase = .ready
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(parsed, bookId: book.id)
                }
            } else {
                // Both parsers came back empty — DRM-locked file or
                // truly malformed EPUB. NOT a backend issue: parsing
                // is fully local in this app. Show the soft-failure
                // surface so the user can see the file path and
                // re-pick if needed.
                phase = .unreadable(fileURL)
                return
            }
            #else
            // macOS: invoke the same python_app pipeline via a
            // short-lived python3 subprocess. Same `EbookFulltext`
            // shape as iOS, so TocDrawer / ReaderView / chapter
            // advancement all work identically. See MacEpubParser.
            do {
                let parsed = try await MacEpubParser.parse(
                    at: fileURL, bookId: book.id
                )
                self.fulltext = parsed
                self.phase = .ready
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(parsed, bookId: book.id)
                }
            } catch {
                phase = .error("EPUB parse failed: \(error.localizedDescription)")
                return
            }
            #endif
        }

        // 4. Reader is on screen. Audio bootstrap is *not* triggered
        // automatically — the user opts in by tapping a play button,
        // which calls `startAudioBootstrap()`. This keeps the reading
        // experience instant and lets users browse the EPUB without
        // ever burning TTS quota.
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
        globalPlayer.isConverting = true
        playerLog.debug("[AudioBootstrap] startAudioBootstrap ch=\(startChapterIndex) — useEmbeddedRuntime=\(settings.useEmbeddedRuntime) hasClient=\(self.client != nil)")

        #if os(iOS) || targetEnvironment(simulator)
        if settings.useEmbeddedRuntime, client == nil {
            // No backend configured — use embedded TTS directly.
            playerLog.debug("[AudioBootstrap] iOS embedded path selected")
            audioBootstrapTask = Task {
                await self.bootstrapEmbedded(chapterIndex: startChapterIndex)
            }
            return
        }
        #endif

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
    #if os(iOS) || targetEnvironment(simulator)
    private func bootstrapEmbedded(chapterIndex startIndex: Int) async {
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded starting at chapter \(startIndex)")

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

        // Per-book output directory inside the app's Caches folder so
        // the OS can evict it under storage pressure without data loss.
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts/\(book.id)", isDirectory: true)

        // Default voice: system language mapped to the closest Edge neural
        // voice.  "auto" lets the Python layer pick based on the book's
        // detected language — same heuristic as the CLI.
        let voice = "auto"

        // Process from startIndex, then wrap to cover earlier chapters.
        let safeStart = max(0, min(startIndex, chapters.count - 1))
        let indices: [Int] = Array(safeStart..<chapters.count) + Array(0..<safeStart)
        var chaptersDone = 0

        for chapterArrayIndex in indices {
            if Task.isCancelled { break }

            // Use the EbookFulltext chapter that corresponds to this index.
            // EbookFulltext.chapters is 0-based in the array but the `index`
            // property is 1-based (matches backend convention). We address by
            // position in the array, not by `.index`.
            let chapter = chapters[chapterArrayIndex]
            let chapterText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chapterText.isEmpty else {
                chaptersDone += 1
                continue
            }

            let totalChapters = chapters.count
            await MainActor.run {
                self.statusBanner = "Generating audio · \(chaptersDone)/\(totalChapters) ready"
            }
            playerLog.debug("[AudioBootstrap] synthesising chapter \(chapterArrayIndex) (\(chapterText.count) chars)")

            do {
                _ = try await PythonBridge.shared.convertChapterStreaming(
                    text: chapterText,
                    voice: voice,
                    outputDir: cacheRoot,
                    chapterIndex: chapterArrayIndex
                ) { [weak globalPlayer] segData, chapIdx, segIdx in
                    // Already dispatched to the main actor by PythonBridge.
                    playerLog.debug("[AudioBootstrap] segment \(segIdx) ch=\(chapIdx) bytes=\(segData.count)")
                    globalPlayer?.enqueueSegment(
                        data: segData,
                        chapterIndex: chapIdx,
                        segmentIndex: segIdx
                    )
                }
                chaptersDone += 1
                playerLog.debug("[AudioBootstrap] chapter \(chapterArrayIndex) complete")
            } catch {
                playerLog.error("[AudioBootstrap] chapter \(chapterArrayIndex) failed: \(error.localizedDescription)")
                // Non-fatal — continue with next chapter so the listener
                // still hears the rest of the book.
            }
        }

        await MainActor.run {
            self.globalPlayer.isConverting = false
            self.statusBanner = nil
        }
        playerLog.debug("[AudioBootstrap] bootstrapEmbedded finished, \(chaptersDone)/\(chapters.count) chapters done")
    }
    #endif

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
            }
            return
        }

        var opts = APIClient.ConvertOptions()
        opts.engine = "edge"
        opts.maxPerformance = true
        do {
            #if os(macOS)
            let response = try await client.submitConversion(localPath: fileURL, options: opts)
            #else
            // On a real iOS device the file URL is a security-scoped
            // bookmark URL; we must call startAccessingSecurityScopedResource
            // before any read syscall and stop immediately after.
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
            #endif
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
            }
        }
    }

    private func subscribeToStream(client: APIClient, jobId: String) {
        streamTask?.cancel()
        streamTask = Task { @MainActor in
            do {
                for try await event in client.eventStream(jobId: jobId) {
                    if Task.isCancelled { break }
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
                            break
                        }
                    }
                }
            } catch {
                self.globalPlayer.isConverting = false
                self.statusBanner = nil
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
