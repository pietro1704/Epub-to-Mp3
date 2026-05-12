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
///
/// Column visibility adapts to the size class:
///   - iPad portrait (compact horizontal) → `.doubleColumn`
///     (sidebar + content; detail slides in on selection).
///   - iPad landscape / macOS → `.all` (three columns side by side).
///   This mirrors Apple Books / Mail, where portrait can't fit three
///   columns without the middle one being unusably narrow.
@available(iOS 16, macOS 13, *)
struct SplitViewRoot: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    #endif

    @State private var columnVisibility: NavigationSplitViewVisibility = SplitViewRoot.defaultColumnVisibility
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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
                .accessibilityIdentifier("split.sidebar")
        } content: {
            Group {
                if let book = selectedBook {
                    ChapterListColumn(
                        book: book,
                        selectedChapterIndex: $selectedChapterIndex
                    )
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                } else {
                    CompatContentUnavailableView(
                        "Select a book",
                        systemImage: "books.vertical",
                        description: Text("Pick a book from the library to see its chapters.")
                    )
                }
            }
            .accessibilityIdentifier("split.content")
        } detail: {
            detailColumn
                .accessibilityIdentifier("split.detail")
        }
        .navigationSplitViewStyle(.balanced)
        // Reset chapter selection when the book changes so the detail
        // column doesn't keep stale state.
        .compatOnChange(of: selectedBookID) { _ in
            selectedChapterIndex = nil
            // In compact layouts (iPad portrait), surface the detail
            // column once the user has picked a book + chapter.
            #if os(iOS)
            if isCompactHorizontal, selectedBookID != nil {
                columnVisibility = .doubleColumn
            }
            #endif
        }
        #if os(iOS)
        // Apply portrait-vs-landscape default when the view appears
        // and again whenever the size class flips (rotation, Slide
        // Over, Split View resize).
        .onAppear { applySizeClassDefault() }
        .compatOnChange(of: hSize) { _ in applySizeClassDefault() }
        .compatOnChange(of: vSize) { _ in applySizeClassDefault() }
        // When the library is empty on iPad portrait the sidebar
        // collapses behind a tiny toggle and the user can't see the
        // import button. Auto-expand to `.all` so the Empty State +
        // import CTA become the immediate focal point; once a book is
        // imported, transition back to `.doubleColumn` so the chapter
        // list owns the content column as before.
        .compatOnChange(of: library.books.count) { _ in applyEmptyLibraryReveal() }
        #endif
    }

    // MARK: - Adaptive column visibility

    /// Default visibility used at first appearance — three columns on
    /// macOS, two on iOS (the size-class observer narrows it further
    /// for portrait iPad after `onAppear` fires).
    private static var defaultColumnVisibility: NavigationSplitViewVisibility {
        #if os(macOS)
        return .all
        #else
        // On iOS we start in the safest layout (two columns) and
        // promote to `.all` when the size-class observer confirms a
        // landscape regular layout. This avoids a flash of an
        // unusably-narrow three-column tree on portrait launch.
        return .doubleColumn
        #endif
    }

    #if os(iOS)
    /// True when the horizontal size class is `.compact` OR the
    /// vertical class is `.regular` (iPad portrait reports `regular`
    /// horizontally but `regular` vertically — we detect portrait by
    /// the vertical class being `.regular` and the horizontal being
    /// `.regular` on iPad; iPhone landscape reports `.compact`
    /// vertically). The simplest reliable proxy for "we don't have
    /// room for three columns" is "vertical class is `.regular` AND
    /// horizontal is `.compact`" — but on iPad portrait the system
    /// reports `hSize == .regular`. We therefore key off the iOS
    /// idiom + interface orientation through `vSize`/`hSize` pair:
    /// portrait iPad → `vSize == .regular`, `hSize == .regular` but
    /// physical width is narrow; the actual signal we use is whether
    /// the trait collection promotes us to three columns naturally.
    ///
    /// Practically: treat anything that isn't `(hSize == .regular &&
    /// vSize == .compact)` as "prefer two columns". That matches
    /// iPad landscape / Mac Catalyst (the only environments where
    /// three columns visually fit) and falls back to two columns for
    /// iPad portrait, iPhone, and Slide Over.
    private var isCompactHorizontal: Bool {
        // iPad landscape: hSize == .regular, vSize == .compact.
        // iPad portrait: hSize == .regular, vSize == .regular.
        // iPhone landscape (Plus/Max): hSize == .regular, vSize == .compact.
        // iPhone everything else: hSize == .compact.
        // We want "three columns ok" only when vSize == .compact AND
        // hSize == .regular (landscape on regular-width devices).
        return !(hSize == .regular && vSize == .compact)
    }

    private func applySizeClassDefault() {
        // Don't trample an explicit user choice mid-session — only
        // realign on transitions between the two canonical layouts.
        let desired = preferredVisibility(for: library.books.isEmpty)
        if columnVisibility != desired {
            columnVisibility = desired
        }
    }

    /// Compute the preferred visibility for the current size class +
    /// library state. Empty library on a layout that would normally
    /// hide the sidebar (iPad portrait → `.doubleColumn`) gets bumped
    /// to `.all` so the Empty State + import button are visible without
    /// requiring the user to tap the toggle. Non-empty libraries fall
    /// back to the canonical size-class default.
    fileprivate func preferredVisibility(for isLibraryEmpty: Bool) -> NavigationSplitViewVisibility {
        if isLibraryEmpty && isCompactHorizontal {
            // iPad portrait / Slide Over with no books: reveal the
            // sidebar so the import CTA is discoverable.
            return .all
        }
        return isCompactHorizontal ? .doubleColumn : .all
    }

    /// Re-evaluate visibility after the library mutates (book imported
    /// or removed). Mirrors `applySizeClassDefault` but keyed off
    /// `library.books.count` so the first import transitions cleanly
    /// from the reveal-the-sidebar layout to the standard two-column
    /// layout and starts revealing the chapter list as the user picks
    /// a book.
    private func applyEmptyLibraryReveal() {
        let desired = preferredVisibility(for: library.books.isEmpty)
        if columnVisibility != desired {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = desired
            }
        }
    }
    #endif

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
