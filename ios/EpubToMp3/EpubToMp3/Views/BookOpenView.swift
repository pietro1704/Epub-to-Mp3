import SwiftUI
import UniformTypeIdentifiers

/// Routes a tapped library book straight into the reader.
///
/// Pipeline (target: visible text in <100 ms on the second open):
///   1. Read the cached `EbookFulltext` from disk → render reader
///      immediately. No network, no waiting.
///   2. If the cache is empty, parse the EPUB on-device with
///      `LocalEpubParser` (still no network) → render reader, save
///      cache for next time.
///   3. Kick off audio in the background: reattach to an existing
///      job if we know its id, otherwise submit a new conversion
///      via `/api/convert`. Either way the reader is already
///      displayed; chapters get audio added to `AVQueuePlayer` as
///      `chapterProgress[i].downloadUrl` lands via SSE.
struct BookOpenView: View {
    let book: BookEntity

    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    @State private var phase: Phase = .resolving
    @State private var fulltext: EbookFulltext?
    @State private var jobSnapshot: JobSnapshot?
    @State private var statusBanner: String?       // top-of-screen "Generating audio…" hint
    @State private var hasAudio: Bool = false
    @State private var audioBootstrapTask: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?
    @State private var showingPicker = false

    enum Phase: Equatable {
        case resolving
        case ready                      // reader rendered, audio status in banner
        case textOnly(URL)              // backend unreachable, just text
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
                if let fulltext {
                    InstantReaderView(
                        fulltext: fulltext,
                        snapshot: $jobSnapshot,
                        statusBanner: statusBanner,
                        hasAudio: hasAudio,
                        backendBaseURL: settings.resolvedBaseURL,
                        coverPNG: book.coverPNG,
                        onRequestAudioRetry: { startAudioBootstrap() }
                    )
                } else {
                    Text("No content available.")
                }

            case .textOnly(let fileURL):
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
            allowedContentTypes: [.epub],
            allowsMultipleSelection: false
        ) { result in
            handleRePick(result)
        }
    }

    // MARK: - Flow

    @MainActor
    private func openFlow() async {
        if isSwiftUIPreview { phase = .ready; return }

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

        // 2. Try the on-disk fulltext cache first. Even on a fresh
        //    install of a book we built locally during the previous
        //    session, this hits.
        if let cached = LocalFulltextCache.read(bookId: book.id) {
            self.fulltext = cached
            self.phase = .ready
        } else {
            // 3. No cache → parse on-device. This is fast (a few ms
            //    on typical novels) and lets us render the reader
            //    without any network round-trip.
            if let parsed = LocalEpubParser.parse(url: fileURL, bookId: book.id) {
                self.fulltext = parsed
                self.phase = .ready
                // Background save so we never hold up the first paint.
                Task.detached(priority: .background) {
                    LocalFulltextCache.save(parsed, bookId: book.id)
                }
            } else {
                // Fall back to local-text-only screen (clear messaging
                // beats a blank reader).
                phase = .textOnly(fileURL)
                return
            }
        }

        // 4. Reader is on screen. Now kick off audio in the background.
        startAudioBootstrap()
    }

    /// Owns the audio bootstrap — reattach to an existing job, or
    /// submit a new conversion. Updates `statusBanner` so the reader
    /// can surface progress without remounting. Idempotent: cancels
    /// any in-flight task before starting a new one.
    @MainActor
    private func startAudioBootstrap() {
        audioBootstrapTask?.cancel()
        statusBanner = "Generating audio…"
        audioBootstrapTask = Task {
            await self.waitForBackendThenBootstrap()
        }
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
            self.statusBanner = "Audio unavailable — open Settings to point at a backend."
        }
    }

    private func bootstrapAudio(client: APIClient) async {
        // Reattach if we have a known job.
        if let existing = book.lastJobId {
            if let snap = try? await client.fetchJob(id: existing) {
                await MainActor.run {
                    self.jobSnapshot = snap
                    self.hasAudio = !snap.playableChapters.isEmpty
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
            let data = try Data(contentsOf: fileURL)
            let response = try await client.submitConversion(
                uploadedFile: (data, fileURL.lastPathComponent),
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
                    self.hasAudio = !snap.playableChapters.isEmpty
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
                        self.hasAudio = !updated.playableChapters.isEmpty
                        self.statusBanner = self.bannerFor(updated)
                        if updated.isTerminal {
                            self.statusBanner = nil
                            break
                        }
                    }
                }
            } catch {
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
    NavigationStack {
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
    .environment(AppSettings())
    .environment(LibraryStore.previewPopulated)
}
#endif
