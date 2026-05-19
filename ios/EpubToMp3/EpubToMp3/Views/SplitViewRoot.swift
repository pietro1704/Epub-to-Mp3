import SwiftUI

/// Two-column root used on iPad regular-width and macOS. Layout:
///
///   Nav sidebar | Detail (full-width content for current mode)
///
/// Falls back to `TabRoot` on iPhone compact and pre-iOS-16/macOS-13
/// systems via the branch in `RootView`.

/// Top-level destinations exposed in the split-view sidebar.
///
/// Order mirrors Apple Books sidebar: Reader first (default), then
/// Library, Conversions, Settings. Now Playing is intentionally absent —
/// the full player surfaces via `FullPlayerSheet` from the `MiniPlayerBar`.
enum SplitNavMode: String, Hashable, CaseIterable, Identifiable {
    case reader
    case library
    case jobs
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reader:   return "Read"
        case .library:  return "Library"
        case .jobs:     return "Conversions"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .reader:   return "text.book.closed"
        case .library:  return "books.vertical"
        case .jobs:     return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@available(iOS 16, macOS 13, *)
struct SplitViewRoot: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playerPresentation: PlayerPresentation

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    #endif

    @State private var columnVisibility: NavigationSplitViewVisibility = SplitViewRoot.defaultColumnVisibility
    /// Default to `.reader` — the landing screen.
    @State private var navMode: SplitNavMode = .reader
    @State private var selectedBookID: String?
    @State private var selectedChapterIndex: Int?

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    /// True when the mini-player footer should appear in the sidebar.
    private var showMiniPlayer: Bool {
        guard let id = currentBookID, !id.isEmpty else { return false }
        return library.books.contains(where: { $0.id == id })
    }

    /// Currently-selected book, resolved through the library store.
    private var selectedBook: BookEntity? {
        guard let id = selectedBookID else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            splitContent
                .zIndex(0)

            // In-tree overlay so the sheet rises from the mini-player
            // strip rather than sliding in from off-screen. Matches the
            // iPhone (TabRoot) presentation.
            if playerPresentation.showingFullPlayer {
                FullPlayerSheet()
                    .environmentObject(player)
                    .environmentObject(library)
                    .transition(.risesFromMiniPlayer)
                    .zIndex(2)
                    .ignoresSafeArea()
            }
        }
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.25)
                : .spring(response: 0.45, dampingFraction: 0.86),
            value: playerPresentation.showingFullPlayer
        )
    }

    private var splitContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            navSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .accessibilityIdentifier("split.sidebar")
        } detail: {
            contentForMode
                .accessibilityIdentifier("split.detail")
        }
        .navigationSplitViewStyle(.balanced)
        .compatOnChange(of: selectedBookID) { _ in
            selectedChapterIndex = nil
            if let bookID = selectedBookID {
                MainReaderView.setCurrentlyReading(bookID: bookID)
            }
            #if os(iOS)
            if isCompactHorizontal, selectedBookID != nil {
                columnVisibility = .doubleColumn
            }
            #endif
        }
        #if os(iOS)
        .onAppear { applySizeClassDefault() }
        .compatOnChange(of: hSize) { _ in applySizeClassDefault() }
        .compatOnChange(of: vSize) { _ in applySizeClassDefault() }
        .compatOnChange(of: library.books.count) { _ in applyEmptyLibraryReveal() }
        .compatOnChange(of: navMode) { _ in applyEmptyLibraryReveal() }
        #endif
    }

    // MARK: - Sidebar

    private var navSidebar: some View {
        List(selection: Binding<SplitNavMode?>(
            get: { navMode },
            set: { if let v = $0 { navMode = v } }
        )) {
            ForEach(SplitNavMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage)
                    .tag(Optional(mode))
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Epub-to-Mp3")
        .accessibilityIdentifier("split.navList")
        // HIG sidebar footer: mini-player docked at the bottom of the
        // sidebar (Sonos / Apple TV / Apple Music pattern). Tap opens
        // the full player sheet. Visible on every sidebar destination
        // so the player bar looks identical regardless of current mode.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showMiniPlayer {
                MiniPlayerBar(onTap: { playerPresentation.showFullPlayer() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("miniPlayer.sidebar")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMiniPlayer)
    }

    // MARK: - Detail (single column)

    @ViewBuilder
    private var contentForMode: some View {
        switch navMode {
        case .reader:
            MainReaderView(
                onOpenPlayer: { playerPresentation.showFullPlayer() },
                onBrowseLibrary: { navMode = .library }
            )
        case .library:
            libraryContent
        case .jobs:
            JobsListView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        // System-rendered back button via NavigationStack. The stack
        // observes `selectedBookID` — pushing/popping a book detail
        // updates the path and SwiftUI draws the standard chevron+title
        // back chrome that matches Apple Books / Music.
        NavigationStack(
            path: Binding<[String]>(
                get: { selectedBookID.map { [$0] } ?? [] },
                set: { stack in
                    selectedBookID = stack.last
                    if stack.isEmpty { selectedChapterIndex = nil }
                }
            )
        ) {
            LibrarySidebar(selectedBookID: $selectedBookID)
                .navigationDestination(for: String.self) { bookID in
                    if let book = library.books.first(where: { $0.id == bookID }) {
                        libraryBookDetail(book: book)
                    }
                }
        }
    }

    @ViewBuilder
    private func libraryBookDetail(book: BookEntity) -> some View {
        Group {
            if let snapshot = jobSnapshot(for: book), let chapterIndex = selectedChapterIndex {
                PlayerReaderDetail(
                    snapshot: snapshot,
                    startingChapterIndex: chapterIndex,
                    backendBaseURL: settings.resolvedBaseURL,
                    onPreviousChapter: { advanceChapter(by: -1, in: snapshot) },
                    onNextChapter: { advanceChapter(by: +1, in: snapshot) }
                )
                .id("\(book.id)-\(chapterIndex)")
            } else {
                ChapterListColumn(
                    book: book,
                    selectedChapterIndex: $selectedChapterIndex
                )
            }
        }
        .navigationTitle(book.title)
        .compatInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    MainReaderView.setCurrentlyReading(bookID: book.id)
                    navMode = .reader
                } label: {
                    Label(L10n.string("library.openInReader"), systemImage: "book.fill")
                }
            }
        }
    }

    // MARK: - Adaptive column visibility

    fileprivate static var defaultColumnVisibility: NavigationSplitViewVisibility {
        #if os(macOS)
        return .all
        #else
        return .doubleColumn
        #endif
    }

    #if os(iOS)
    private var isCompactHorizontal: Bool {
        return !(hSize == .regular && vSize == .compact)
    }

    private func applySizeClassDefault() {
        let desired = preferredVisibility(for: shouldRevealEmptyLibrarySidebar)
        if columnVisibility != desired {
            columnVisibility = desired
        }
    }

    private var shouldRevealEmptyLibrarySidebar: Bool {
        return navMode == .library && library.books.isEmpty
    }

    fileprivate func preferredVisibility(for needsEmptySidebarReveal: Bool) -> NavigationSplitViewVisibility {
        if needsEmptySidebarReveal && isCompactHorizontal {
            return .all
        }
        return isCompactHorizontal ? .doubleColumn : .all
    }

    private func applyEmptyLibraryReveal() {
        let desired = preferredVisibility(for: shouldRevealEmptyLibrarySidebar)
        if columnVisibility != desired {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = desired
            }
        }
    }
    #endif


    // MARK: - Helpers

    private func jobSnapshot(for book: BookEntity) -> JobSnapshot? {
        #if DEBUG
        if isSwiftUIPreview {
            return book.lastJobId != nil ? JobSnapshot.previewSample : nil
        }
        #endif
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

/// Thin wrapper around `PlayerReaderView` that adds keyboard shortcuts.
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
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
}

@available(iOS 16, macOS 13, *)
#Preview("SplitViewRoot — empty") {
    SplitViewRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore.previewEmpty)
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
}
#endif
