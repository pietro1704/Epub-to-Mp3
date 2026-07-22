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
///     the book currently being read, then opens the shared full-player
///     flow via `PlayerPresentation`. `MainReaderView` no longer owns a
///     fallback local sheet; presentation lives in the root container.
struct MainReaderView: View {

    // MARK: - Dependencies

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var playerPresentation: PlayerPresentation

    // MARK: - AppStorage keys

    /// The book the user last opened in the reader. Written here and by
    /// any other entry point that opens a book for reading (e.g. tapping a
    /// library row).
    @AppStorage(MainReaderView.currentlyReadingBookIDKey)
    private var currentlyReadingBookID: String?

    /// Invoked when the user taps "Browse Library".
    var onBrowseLibrary: (() -> Void)?

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
        // No `.navigationTitle` here: the in-book reader hides
        // NavigationStack's bar entirely (`InstantReaderView` renders
        // its own `customTopBar`). The empty-state has its own visual
        // title inside the view body, so it doesn't need the nav bar
        // either. Leaving the modifier off avoids two competing
        // chrome bars stacking on the empty state.
        // Auto-clear if the reading book was removed from the library so
        // we don't stay in a permanently-blank "populated" state.
        .compatOnChange(of: library.books.map(\.id)) { _ in
            if let id = currentlyReadingBookID,
               !library.books.contains(where: { $0.id == id }) {
                currentlyReadingBookID = nil
            }
        }
    }

    // MARK: - Populated reader

    @ViewBuilder
    private func populatedReader(for book: BookEntity) -> some View {
        BookOpenView(book: book, onClose: {
            currentlyReadingBookID = nil
            onBrowseLibrary?()
        })
            .onAppear {
                var updated = book
                updated.lastOpenedAt = Date()
                library.update(updated)
            }
            .toolbar {
                ToolbarItem(placement: .compatPrimaryTrailing) {
                    listenButton
                }
            }
    }

    // MARK: - Toolbar "Listen" button

    /// One tap mirrors the reading book into the shared playing pointer,
    /// then asks the global presentation coordinator to show the full player.
    @ViewBuilder
    private var listenButton: some View {
        if currentBook?.lastJobId != nil {
            Button {
                // Mirror reading book to playing book so Now Playing /
                // PlayerReaderView start from the same book.
                if let id = currentlyReadingBookID {
                    UserDefaults.standard.set(id, forKey: AudioPlayer.currentBookIDDefaultsKey)
                }
                playerPresentation.showFullPlayer()
            } label: {
                Label(L10n.string("mainReader.listen"), systemImage: "headphones")
            }
            .accessibilityIdentifier("mainReader.listen")
            .help(L10n.string("mainReader.listenHelp"))
        }
    }

    // MARK: - Empty state (HIG ContentUnavailableView pattern)

    private var emptyState: some View {
        VStack(spacing: 20) {
            CompatContentUnavailableView(
                L10n.string("mainReader.pickBook"),
                systemImage: "book.closed",
                description: Text(localized: "mainReader.pickBookDescription")
            )
            if let onBrowseLibrary {
                Button {
                    onBrowseLibrary()
                } label: {
                    Label(L10n.string("mainReader.browseLibrary"), systemImage: "books.vertical")
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
        .environmentObject(PlayerPresentation())
}

#Preview("MainReader — populated (no audio)") {
    let lib = LibraryStore.previewPopulated
    if let first = lib.books.first {
        UserDefaults.standard.set(first.id, forKey: MainReaderView.currentlyReadingBookIDKey)
    }
    return MainReaderView(onBrowseLibrary: {})
        .environmentObject(AppSettings())
        .environmentObject(lib)
        .environmentObject(PlayerPresentation())
}

#Preview("MainReader — populated (with audio)") {
    let lib = LibraryStore.previewPopulated
    // pick a book that has a jobId so the Listen button appears
    if let book = lib.books.first(where: { $0.lastJobId != nil }) {
        UserDefaults.standard.set(book.id, forKey: MainReaderView.currentlyReadingBookIDKey)
    }
    return MainReaderView(onBrowseLibrary: {})
        .environmentObject(AppSettings())
        .environmentObject(lib)
        .environmentObject(PlayerPresentation())
}
#endif
