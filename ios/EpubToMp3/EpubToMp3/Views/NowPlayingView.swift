import SwiftUI

/// Landing screen for the iOS, iPadOS and macOS apps. Mirrors the
/// Apple Books / Apple Podcasts "Now Playing" affordance: when the user
/// has a current audiobook, the player + reader is the FIRST thing they
/// see on launch; the Library becomes a navigable destination rather
/// than the default surface.
///
/// Persistence model:
///   - `@AppStorage(AudioPlayer.currentBookIDDefaultsKey)` holds the
///     `BookEntity.id` of the last-played book.
///   - `@AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)` holds
///     the zero-based chapter index where the user left off.
/// Both are written by `NowPlayingView` itself when the player mounts a
/// new book (see `bind(bookID:chapterIndex:)`). The view re-renders
/// reactively when the stored value changes — switching from the empty
/// state to the populated player without further wiring.
///
/// Empty-state contract:
///   - When no book is "currently playing", we show a HIG-style empty
///     state (cf. `ContentUnavailableView`) with a single CTA that
///     pushes the user toward the Library via `onBrowseLibrary` — the
///     caller decides whether that's "select the Library tab" or "swap
///     the split-view nav mode" so the same view fits both root layouts.
struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    /// Persisted "currently playing" book — driven by the user's most
    /// recent playback action. The empty / populated branch keys on
    /// whether this resolves to an in-library book.
    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)
    private var currentChapterIndex: Int = 0

    /// Called when the empty-state CTA fires. The hosting root chooses
    /// whether to swap tabs (iPhone `TabRoot`) or change nav mode
    /// (iPad/macOS `SplitViewRoot`). Optional so the view stays usable
    /// in previews / tests where no router is wired up.
    var onBrowseLibrary: (() -> Void)?

    /// Currently-resolved book. `nil` either when no id is persisted or
    /// when the id no longer matches any library entry (book deleted).
    private var currentBook: BookEntity? {
        guard let id = currentBookID, !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let book = currentBook {
                populatedBody(for: book)
            } else {
                emptyBody
            }
        }
        // Auto-clear the persisted id if the book has been removed from
        // the library (otherwise the user lands on a permanently-empty
        // populated view that can never resolve a snapshot).
        .compatOnChange(of: library.books.map(\.id)) { _ in
            if let id = currentBookID,
               !library.books.contains(where: { $0.id == id }) {
                currentBookID = nil
            }
        }
    }

    // MARK: - Populated

    @ViewBuilder
    private func populatedBody(for book: BookEntity) -> some View {
        if let snapshot = makeSnapshot(for: book) {
            PlayerReaderView(
                snapshot: snapshot,
                backendBaseURL: settings.resolvedBaseURL
            )
            // Re-mount when the user switches books so PlayerReaderView's
            // @StateObject `player` reloads cleanly with the new queue.
            .id("nowplaying-\(book.id)-\(currentChapterIndex)")
        } else {
            // Book exists in the library but has never been converted —
            // direct the user to the library to start a conversion.
            noJobBody(for: book)
        }
    }

    /// Compose a minimal `JobSnapshot` stub anchored on the book's
    /// `lastJobId`. `PlayerReaderView` re-fetches the live state over
    /// SSE on `bootstrap()`, so the stub only needs the identifiers.
    /// Returns `nil` when the book has never been converted.
    private func makeSnapshot(for book: BookEntity) -> JobSnapshot? {
        if isSwiftUIPreview {
            return book.lastJobId != nil ? JobSnapshot.previewSample : nil
        }
        guard let jobId = book.lastJobId else { return nil }
        return JobSnapshot(
            jobId: jobId,
            state: "running",
            bookTitle: book.resolvedTitle,
            bookAuthor: book.author,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: nil,
            chaptersCompleted: nil,
            chapterProgress: nil,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }

    @ViewBuilder
    private func noJobBody(for book: BookEntity) -> some View {
        CompatContentUnavailableView(
            "No audio yet",
            systemImage: "books.vertical",
            description: Text(
                "‘\(book.resolvedTitle)’ hasn’t been converted yet. Open it from the library to start a conversion."
            )
        )
        .overlay(alignment: .bottom) {
            if let onBrowseLibrary {
                Button {
                    onBrowseLibrary()
                } label: {
                    Label("Open in library", systemImage: "books.vertical")
                        .frame(minHeight: 44)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 48)
                .accessibilityIdentifier("nowPlaying.openInLibrary")
            }
        }
    }

    // MARK: - Empty

    private var emptyBody: some View {
        VStack(spacing: 16) {
            CompatContentUnavailableView(
                "Start a new audiobook",
                systemImage: "headphones.circle",
                description: Text("Import an EPUB from your library to convert and play it here.")
            )
            if let onBrowseLibrary {
                Button {
                    onBrowseLibrary()
                } label: {
                    Label("Browse Library", systemImage: "books.vertical")
                        .frame(minHeight: 44)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("nowPlaying.browseLibrary")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers (callable from siblings to set the "currently playing" pointer)

extension NowPlayingView {
    /// Persist the (bookID, chapterIndex) pointer used by `NowPlayingView`.
    /// Call this from the library / chapter-list flow when the user
    /// starts playing a chapter so the landing view rehydrates with the
    /// right book on next launch.
    static func setCurrentlyPlaying(
        bookID: String?,
        chapterIndex: Int,
        defaults: UserDefaults = .standard
    ) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: AudioPlayer.currentBookIDDefaultsKey)
            defaults.set(max(0, chapterIndex), forKey: AudioPlayer.currentChapterIndexDefaultsKey)
        } else {
            defaults.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
            defaults.removeObject(forKey: AudioPlayer.currentChapterIndexDefaultsKey)
        }
    }
}

#if DEBUG
#Preview("Now Playing — empty") {
    NowPlayingView()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore.previewEmpty)
}

#Preview("Now Playing — populated") {
    // Seed the AppStorage so the populated branch renders in the canvas.
    let lib = LibraryStore.previewPopulated
    if let first = lib.books.first {
        UserDefaults.standard.set(first.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
    }
    return NowPlayingView()
        .environmentObject(AppSettings())
        .environmentObject(lib)
}
#endif
