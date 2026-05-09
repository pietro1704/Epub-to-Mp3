import SwiftUI

/// Routes a tapped library book to the right experience:
///
/// - If the book has a `lastJobId` and the backend confirms the job
///   exists, render the existing `PlayerReaderView` against that
///   snapshot — that's the audio + reader hero.
/// - Otherwise, register the local EPUB with the sidecar
///   (`/api/uploads/local`), submit a new conversion using the user's
///   stored defaults, and immediately open `PlayerReaderView`. The
///   reader shows the EPUB text; the player streams TTS chapter by
///   chapter as the backend produces them (slice-3 fulltext + SSE +
///   chapter download URLs already support this — no new server-side
///   plumbing needed).
///
/// This view never blocks reading: even if the conversion request hasn't
/// returned yet, the reader pane shows the EPUB text the moment the
/// fulltext endpoint answers.
struct BookOpenView: View {
    let book: BookEntity

    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    @State private var snapshot: JobSnapshot?
    @State private var phase: Phase = .resolving
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case resolving                 // figuring out which job (if any) to attach
        case loading(message: String)  // hitting the backend
        case ready                     // have a snapshot, render PlayerReader
        case textOnly(URL)             // no backend reachable — fall back to local-only reader
        case error(String)
    }

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    var body: some View {
        Group {
            switch phase {
            case .resolving, .loading:
                ProgressView(loadingLabel)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let snap = snapshot {
                    PlayerReaderView(
                        snapshot: snap,
                        backendBaseURL: settings.resolvedBaseURL
                    )
                } else {
                    Text("No snapshot available.")
                }
            case .textOnly(let fileURL):
                LocalEpubReaderView(fileURL: fileURL, book: book)
            case .error(let msg):
                VStack(spacing: 12) {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Retry") { Task { await bootstrap() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(book.resolvedTitle)
        .compatInlineNavigationTitle()
        .task { await bootstrap() }
    }

    private var loadingLabel: String {
        if case .loading(let m) = phase { return m }
        return "Opening \(book.resolvedTitle)…"
    }

    @MainActor
    private func bootstrap() async {
        phase = .resolving
        guard let client else {
            // No backend — open in text-only mode if we can.
            if let fileURL = try? library.openBookFile(id: book.id) {
                phase = .textOnly(fileURL)
            } else {
                phase = .error("Cannot open the EPUB file. Try re-importing it.")
            }
            return
        }

        // 1. If we already have a job for this book, try to attach.
        if let existing = book.lastJobId {
            phase = .loading(message: "Reattaching to existing audio…")
            if let snap = try? await client.fetchJob(id: existing) {
                snapshot = snap
                phase = .ready
                return
            }
            // Stale id — fall through to start a new conversion.
        }

        // 2. Resolve the local file URL.
        let fileURL: URL
        do {
            fileURL = try library.openBookFile(id: book.id)
        } catch {
            phase = .error("Cannot open the EPUB file: \(error.localizedDescription)")
            return
        }

        // 3. Kick off a streaming conversion. We don't wait for it to
        //    finish — as soon as the backend hands back a jobId we can
        //    open `PlayerReaderView`, which subscribes to SSE and starts
        //    rendering chapters as their `downloadUrl` becomes
        //    available.
        phase = .loading(message: "Preparing audio stream…")
        do {
            var opts = APIClient.ConvertOptions()
            opts.engine = "edge"
            opts.maxPerformance = true
            #if os(macOS)
            let response = try await client.submitConversion(localPath: fileURL, options: opts)
            #else
            // iOS path — multipart upload of the bytes.
            let data = try Data(contentsOf: fileURL)
            let response = try await client.submitConversion(
                uploadedFile: (data, fileURL.lastPathComponent),
                options: opts
            )
            #endif

            // Update the library with the fresh job id so subsequent
            // opens reattach.
            var updated = book
            updated.lastJobId = response.jobId
            updated.lastOpenedAt = Date()
            library.update(updated)

            // Pull the first snapshot so PlayerReaderView can mount.
            phase = .loading(message: "Connecting to job \(response.jobId.prefix(8))…")
            let snap = try await client.fetchJob(id: response.jobId)
            self.snapshot = snap
            self.phase = .ready
        } catch {
            // Conversion failed — still let the user read the text.
            self.errorMessage = error.localizedDescription
            self.phase = .textOnly(fileURL)
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
