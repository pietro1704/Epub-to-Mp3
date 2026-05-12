import SwiftUI

/// Multi-column root used on iPad regular-width and macOS. Layout:
///
///   Nav sidebar | Content for current nav mode | Detail (library only)
///
/// As of the Now-Playing landing-screen slice, the sidebar surfaces a
/// short top-level navigation (`SplitNavMode`) rather than the library
/// book list directly. Default selection is `.nowPlaying` — the player
/// + reader for the user's most-recent audiobook — mirroring Apple
/// Books / Apple Podcasts. Library is one step away.
///
/// Falls back to `TabRoot` on iPhone compact and pre-iOS-16/macOS-13
/// systems via the branch in `RootView`. This view is therefore safe
/// to compile under iOS 15 / macOS 12 SDKs — the `@available` gate
/// keeps the body from executing on older OSes.
///
/// Selection model:
///   - `navMode: SplitNavMode` — drives the sidebar + content column.
///   - `selectedBookID: String?` — relevant only when `navMode == .library`.
///   - `selectedChapterIndex: Int?` — relevant only when `navMode == .library`.
///
/// Column visibility adapts to the size class:
///   - iPad portrait (compact horizontal) → `.doubleColumn`
///     (sidebar + content; detail slides in on selection).
///   - iPad landscape / macOS → `.all` (three columns side by side).
///   This mirrors Apple Books / Mail, where portrait can't fit three
///   columns without the middle one being unusably narrow.

/// Top-level destinations exposed in the split-view sidebar. Backed by
/// `String` so it can flow through `List(selection:)` on every SDK
/// without bridging through `Hashable`-only generic plumbing.
enum SplitNavMode: String, Hashable, CaseIterable, Identifiable {
    case nowPlaying
    case library
    case jobs
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .library:    return "Library"
        case .jobs:       return "Conversions"
        case .settings:   return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: return "headphones.circle"
        case .library:    return "books.vertical"
        case .jobs:       return "arrow.triangle.2.circlepath"
        case .settings:   return "gearshape"
        }
    }
}

@available(iOS 16, macOS 13, *)
struct SplitViewRoot: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    #endif

    @State private var columnVisibility: NavigationSplitViewVisibility = SplitViewRoot.defaultColumnVisibility
    @State private var navMode: SplitNavMode = .nowPlaying
    @State private var selectedBookID: String?
    @State private var selectedChapterIndex: Int?

    /// Currently-selected book, resolved through the library store.
    private var selectedBook: BookEntity? {
        guard let id = selectedBookID else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            navSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .accessibilityIdentifier("split.sidebar")
        } content: {
            contentColumn
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
        // When the library is empty AND the user is on the Library
        // destination, auto-expand to `.all` on iPad portrait so the
        // Empty State + import CTA become the immediate focal point;
        // once a book is imported, transition back to `.doubleColumn`.
        .compatOnChange(of: library.books.count) { _ in applyEmptyLibraryReveal() }
        .compatOnChange(of: navMode) { _ in applyEmptyLibraryReveal() }
        #endif
    }

    // MARK: - Sidebar

    private var navSidebar: some View {
        // `List(_:selection:rowContent:)` for non-Set selection is
        // macOS-only on the SDKs we support. Use the multi-purpose
        // initializer with an explicit `ForEach` + tag so the same body
        // compiles on iOS 15 / iPadOS 16 / macOS 12.
        List(selection: Binding<SplitNavMode?>(
            get: { navMode },
            set: { newValue in if let v = newValue { navMode = v } }
        )) {
            ForEach(SplitNavMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage)
                    .tag(Optional<SplitNavMode>.some(mode))
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Epub-to-Mp3")
        .accessibilityIdentifier("split.navList")
    }

    // MARK: - Content column

    @ViewBuilder
    private var contentColumn: some View {
        switch navMode {
        case .nowPlaying:
            NowPlayingView(onBrowseLibrary: { navMode = .library })
        case .library:
            LibrarySidebar(selectedBookID: $selectedBookID)
        case .jobs:
            JobsListView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Adaptive column visibility

    /// Default visibility used at first appearance — three columns on
    /// macOS, two on iOS (the size-class observer narrows it further
    /// for portrait iPad after `onAppear` fires).
    fileprivate static var defaultColumnVisibility: NavigationSplitViewVisibility {
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
    /// Treat anything that isn't `(hSize == .regular && vSize ==
    /// .compact)` as "prefer two columns". That matches iPad landscape
    /// (the only environment where three columns visually fit) and
    /// falls back to two columns for iPad portrait, iPhone, and Slide
    /// Over.
    private var isCompactHorizontal: Bool {
        return !(hSize == .regular && vSize == .compact)
    }

    private func applySizeClassDefault() {
        // Don't trample an explicit user choice mid-session — only
        // realign on transitions between the two canonical layouts.
        let desired = preferredVisibility(for: shouldRevealEmptyLibrarySidebar)
        if columnVisibility != desired {
            columnVisibility = desired
        }
    }

    /// True only on the Library destination with an empty library and
    /// a compact horizontal class — that's the one case where the
    /// import CTA needs the sidebar revealed.
    private var shouldRevealEmptyLibrarySidebar: Bool {
        return navMode == .library && library.books.isEmpty
    }

    /// Compute the preferred visibility for the current size class +
    /// library state. Empty library on a layout that would normally
    /// hide the sidebar (iPad portrait → `.doubleColumn`) gets bumped
    /// to `.all` so the Empty State + import button are visible without
    /// requiring the user to tap the toggle.
    fileprivate func preferredVisibility(for needsEmptySidebarReveal: Bool) -> NavigationSplitViewVisibility {
        if needsEmptySidebarReveal && isCompactHorizontal {
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
        let desired = preferredVisibility(for: shouldRevealEmptyLibrarySidebar)
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
        switch navMode {
        case .nowPlaying, .jobs, .settings:
            // These destinations are full-bleed inside the content
            // column — the detail column gets a quiet placeholder.
            CompatContentUnavailableView(
                "—",
                systemImage: "headphones",
                description: Text("")
            )
            .hidden()
        case .library:
            libraryDetailColumn
        }
    }

    @ViewBuilder
    private var libraryDetailColumn: some View {
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
            } else if selectedChapterIndex == nil, let book = selectedBook {
                ChapterListColumn(
                    book: book,
                    selectedChapterIndex: $selectedChapterIndex
                )
            } else {
                CompatContentUnavailableView(
                    "Pick a chapter",
                    systemImage: "headphones",
                    description: Text("Select a chapter to start playback.")
                )
            }
        } else {
            CompatContentUnavailableView(
                "Pick a book",
                systemImage: "books.vertical",
                description: Text("Choose a book from the library to see its chapters.")
            )
        }
    }

    // MARK: - Helpers

    /// Resolve a `JobSnapshot` for the currently-selected book. Mirrors
    /// the SSE-aware design of `PlayerReaderView` — the stub passes the
    /// minimum required identifiers; live data lands via the event
    /// stream inside the player view.
    private func jobSnapshot(for book: BookEntity) -> JobSnapshot? {
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
/// every Mac).
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
