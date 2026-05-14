import SwiftUI

/// Root-level reader surface. This is the **landing screen** of the app
/// on every device (iPhone tab 0, iPad/macOS sidebar default).
///
/// Landing logic:
///   - `currentlyReadingBookID` (AppStorage) stores the last book the user
///     opened for *reading* — independent of `currentlyPlayingBookID` which
///     drives the audio player.
///   - When set and present in the library, resolves the book and routes
///     into `BookOpenView` (the full reader + optional audio bootstrap path).
///   - When nil (first launch or all books removed), shows the HIG empty
///     state with a single "Browse Library" CTA.
///
/// "Listen" affordance:
///   - A toolbar button (headphones icon) sets `currentlyPlayingBookID` to
///     the book currently being read, then calls `onOpenPlayer` so the host
///     root navigates to Now Playing. This keeps the reading→listening flow
///     one tap and avoids duplicating the audio bootstrap inside this view.
struct MainReaderView: View {

    // MARK: - Dependencies

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    // MARK: - AppStorage keys

    /// The book the user last opened in the reader. Written here and by
    /// any other entry point that opens a book for reading (e.g. tapping a
    /// library row).
    @AppStorage(MainReaderView.currentlyReadingBookIDKey)
    private var currentlyReadingBookID: String?

    // MARK: - Router callbacks

    /// Invoked when the user taps "Listen" so the host root (TabRoot /
    /// SplitViewRoot) can navigate to the Now Playing destination.
    /// Optional — omit in previews / tests.
    var onOpenPlayer: (() -> Void)?

    /// Invoked when the user taps "Browse Library".
    var onBrowseLibrary: (() -> Void)?

    // MARK: - Private state

    @State private var showingPlayerOverlay: Bool = false

    // MARK: - Derived

    private var currentBook: BookEntity? {
        guard let id = currentlyReadingBookID, !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let book = currentBook {
                populatedReader(for: book)
            } else {
                emptyState
            }
        }
        // Auto-clear if the reading book was removed from the library so
        // we don't stay in a permanently-blank "populated" state.
        .compatOnChange(of: library.books.map(\.id)) { _ in
            if let id = currentlyReadingBookID,
               !library.books.contains(where: { $0.id == id }) {
                currentlyReadingBookID = nil
            }
        }
        .background {
            Color.clear.allowsHitTesting(false)
                .sheet(isPresented: $showingPlayerOverlay) {
                    if let book = currentBook,
                       let jobId = book.lastJobId {
                        let stub = makeStub(for: book, jobId: jobId)
                        PlayerReaderView(
                            snapshot: stub,
                            backendBaseURL: settings.resolvedBaseURL
                        )
                        .environmentObject(settings)
                    } else {
                        CompatContentUnavailableView(
                            "No audio yet",
                            systemImage: "headphones",
                            description: Text("Convert this book first to listen along.")
                        )
                    }
                }
        }
    }

    // MARK: - Populated reader

    @ViewBuilder
    private func populatedReader(for book: BookEntity) -> some View {
        BookOpenView(book: book)
            .toolbar {
                ToolbarItem(placement: .compatPrimaryTrailing) {
                    listenButton
                }
            }
            // Update reading pointer every time this view mounts with a book,
            // so tapping a library row always refreshes the landing.
            .onAppear {
                var updated = book
                updated.lastOpenedAt = Date()
                library.update(updated)
            }
    }

    // MARK: - Toolbar "Listen" button

    /// One tap opens the player. On iPhone it navigates to the Now Playing
    /// tab (via `onOpenPlayer`). On iPad/macOS where there is no tab bar,
    /// it presents the player as a sheet overlay.
    @ViewBuilder
    private var listenButton: some View {
        if currentBook?.lastJobId != nil {
            Button {
                // Mirror reading book to playing book so Now Playing /
                // PlayerReaderView start from the same book.
                if let id = currentlyReadingBookID {
                    UserDefaults.standard.set(id, forKey: AudioPlayer.currentBookIDDefaultsKey)
                }
                if let cb = onOpenPlayer {
                    cb()
                } else {
                    showingPlayerOverlay = true
                }
            } label: {
                Label("Listen", systemImage: "headphones")
            }
            .accessibilityIdentifier("mainReader.listen")
            .help("Open audio player for this book")
        }
    }

    // MARK: - Empty state (HIG ContentUnavailableView pattern)

    private var emptyState: some View {
        VStack(spacing: 20) {
            CompatContentUnavailableView(
                "Pick a book to read",
                systemImage: "book.closed",
                description: Text("Import an EPUB or pick a book from your library to start reading.")
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
                .accessibilityIdentifier("mainReader.browseLibrary")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func makeStub(for book: BookEntity, jobId: String) -> JobSnapshot {
        JobSnapshot(
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
}

// MARK: - Static helpers

extension MainReaderView {

    /// AppStorage key for the currently-reading book id.
    static let currentlyReadingBookIDKey = "currentlyReadingBookID"

    /// Persist the currently-reading book pointer. Call this from
    /// LibraryView / ChapterListColumn when the user taps "Open" on a book
    /// so MainReaderView's landing screen rehydrates after navigation.
    static func setCurrentlyReading(
        bookID: String?,
        defaults: UserDefaults = .standard
    ) {
        if let bookID, !bookID.isEmpty {
            defaults.set(bookID, forKey: currentlyReadingBookIDKey)
        } else {
            defaults.removeObject(forKey: currentlyReadingBookIDKey)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("MainReader — empty") {
    MainReaderView(onBrowseLibrary: {})
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore.previewEmpty)
}

#Preview("MainReader — populated (no audio)") {
    let lib = LibraryStore.previewPopulated
    if let first = lib.books.first {
        UserDefaults.standard.set(first.id, forKey: MainReaderView.currentlyReadingBookIDKey)
    }
    return MainReaderView(onOpenPlayer: {}, onBrowseLibrary: {})
        .environmentObject(AppSettings())
        .environmentObject(lib)
}

#Preview("MainReader — populated (with audio)") {
    let lib = LibraryStore.previewPopulated
    // pick a book that has a jobId so the Listen button appears
    if let book = lib.books.first(where: { $0.lastJobId != nil }) {
        UserDefaults.standard.set(book.id, forKey: MainReaderView.currentlyReadingBookIDKey)
    }
    return MainReaderView(onOpenPlayer: {}, onBrowseLibrary: {})
        .environmentObject(AppSettings())
        .environmentObject(lib)
}
#endif
