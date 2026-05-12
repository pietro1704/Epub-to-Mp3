import SwiftUI

/// Three-column root used on iPad regular-width and macOS. Layout:
///
///   Library (sidebar) | ChapterList (content) | PlayerReader (detail)
///
/// Falls back to `TabRoot` on iPhone compact and pre-iOS-16/macOS-13
/// systems via the branch in `RootView`. This view is therefore safe
/// to compile under iOS 15 / macOS 12 SDKs — the `@available` gate
/// keeps the body from executing on older OSes.
///
/// Selection model:
///   - `selectedBookID: String?`  — drives the sidebar.
///   - `selectedChapterIndex: Int?` — drives the chapter list, which
///     in turn mounts the detail column on selection change.
///
/// Both are persistent across re-layouts but reset to nil when the
/// underlying library changes (book removed).
@available(iOS 16, macOS 13, *)
struct SplitViewRoot: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedBookID: String?
    @State private var selectedChapterIndex: Int?

    /// Currently-selected book, resolved through the library store.
    private var selectedBook: BookEntity? {
        guard let id = selectedBookID else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(selectedBookID: $selectedBookID)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            if let book = selectedBook {
                ChapterListColumn(
                    book: book,
                    selectedChapterIndex: $selectedChapterIndex
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
            } else {
                CompatContentUnavailableView(
                    "Select a book",
                    systemImage: "books.vertical",
                    description: Text("Pick a book from the library to see its chapters.")
                )
            }
        } detail: {
            detailColumn
        }
        // Reset chapter selection when the book changes so the detail
        // column doesn't keep stale state.
        .compatOnChange(of: selectedBookID) { _ in
            selectedChapterIndex = nil
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let book = selectedBook {
            if let snapshot = jobSnapshot(for: book), let chapterIndex = selectedChapterIndex {
                PlayerReaderDetail(
                    snapshot: snapshot,
                    startingChapterIndex: chapterIndex,
                    backendBaseURL: settings.resolvedBaseURL,
                    onPreviousChapter: { advanceChapter(by: -1, in: snapshot) },
                    onNextChapter: { advanceChapter(by: +1, in: snapshot) }
                )
                // Re-mount when the chapter index changes so the
                // PlayerReaderView's @State `player` reloads cleanly
                // at the new starting chapter.
                .id("\(book.id)-\(chapterIndex)")
            } else {
                CompatContentUnavailableView(
                    "Pick a chapter",
                    systemImage: "headphones",
                    description: Text("Select a chapter from the middle column to start playback.")
                )
            }
        } else {
            CompatContentUnavailableView(
                "Pick a chapter",
                systemImage: "headphones",
                description: Text("Choose a book first, then pick one of its chapters.")
            )
        }
    }

    // MARK: - Helpers

    /// Resolve a `JobSnapshot` for the currently-selected book. In
    /// production this would mirror what `ChapterListColumn` fetches;
    /// for the slice we read from the (in-progress) preview fixture
    /// when running in the canvas and otherwise rely on the fact that
    /// the user navigated through `ChapterListColumn` — which means
    /// the snapshot has already been loaded over the wire and the
    /// chapter index it produced is meaningful.
    ///
    /// The detail view passes the same `backendBaseURL`, so live
    /// streaming updates land via `PlayerReaderView.subscribeToJobStream`.
    private func jobSnapshot(for book: BookEntity) -> JobSnapshot? {
        // Preview fallback: keep the canvas alive without network.
        if isSwiftUIPreview {
            return book.lastJobId != nil ? JobSnapshot.previewSample : nil
        }
        // We don't cache snapshots at this level; `PlayerReaderView`
        // owns its own state. Compose a minimal snapshot stub anchored
        // on the book's `lastJobId` so the player has something to
        // hand to the AudioPlayer; PlayerReaderView re-fetches the
        // full state via SSE on `bootstrap()`.
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

    /// Move the chapter selection by `delta`, clamped to the snapshot's
    /// playable chapters. Used by the keyboard shortcuts.
    private func advanceChapter(by delta: Int, in snapshot: JobSnapshot) {
        let chapters = snapshot.playableChapters
        guard !chapters.isEmpty else { return }
        let current = selectedChapterIndex ?? chapters.first?.index ?? 0
        let positions = chapters.map { $0.index }
        guard let cursor = positions.firstIndex(of: current) else {
            selectedChapterIndex = chapters.first?.index
            return
        }
        let next = max(0, min(positions.count - 1, cursor + delta))
        selectedChapterIndex = positions[next]
    }
}

/// Thin wrapper around `PlayerReaderView` that adds keyboard
/// shortcuts for hardware-keyboard users (Magic Keyboard on iPad,
/// every Mac). Gated behind iOS 17 / macOS 14 because `onKeyPress`
/// is what enables the shortcut delivery on SwiftUI containers
/// without focus juggling.
@available(iOS 16, macOS 13, *)
private struct PlayerReaderDetail: View {
    let snapshot: JobSnapshot
    let startingChapterIndex: Int
    let backendBaseURL: URL?
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void

    var body: some View {
        PlayerReaderView(
            snapshot: snapshot,
            backendBaseURL: backendBaseURL
        )
        // Space toggles play/pause via the existing transport buttons.
        // Arrow keys move chapter selection in the split layout — the
        // player itself will follow when its state observer fires the
        // re-render via `.id()`.
        .compatOnKeyPressArrowsAndPaging { key in
            switch key {
            case .leftArrow, .pageUp:
                onPreviousChapter()
                return true
            case .rightArrow, .pageDown:
                onNextChapter()
                return true
            default:
                return false
            }
        }
    }
}

#if DEBUG
@available(iOS 16, macOS 13, *)
#Preview("SplitViewRoot — populated") {
    SplitViewRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore.previewPopulated)
}

@available(iOS 16, macOS 13, *)
#Preview("SplitViewRoot — empty") {
    SplitViewRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore.previewEmpty)
}
#endif
