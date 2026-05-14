import SwiftUI

/// Multi-column root used on iPad regular-width and macOS. Layout:
///
///   Nav sidebar | Content for current nav mode | Detail (library only)
///
/// As of the Music/Spotify-style player slice, the `.nowPlaying` sidebar
/// destination has been removed. The full player is now presented as a
/// `FullPlayerSheet` via `MiniPlayerBar` tap — the same sheet pattern as
/// the iPhone tab layout. This keeps the sidebar lean (Read | Library |
/// Conversions | Settings) and the full-screen player available from any
/// surface.
///
/// Falls back to `TabRoot` on iPhone compact and pre-iOS-16/macOS-13
/// systems via the branch in `RootView`. This view is therefore safe to
/// compile under iOS 15 / macOS 12 SDKs — the `@available` gate keeps
/// the body from executing on older OSes.

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
        // Full-player sheet — presented from mini-player tap.
        .sheet(isPresented: $playerPresentation.showingFullPlayer) {
            FullPlayerSheet()
                .environmentObject(player)
                .environmentObject(library)
        }
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
        // the full player sheet.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showMiniPlayer, navMode != .reader {
                MiniPlayerBar(onTap: { playerPresentation.showFullPlayer() })
                    .accessibilityIdentifier("miniPlayer.sidebar")
            }
        }
    }

    // MARK: - Content column

    @ViewBuilder
    private var contentColumn: some View {
        switch navMode {
        case .reader:
            MainReaderView(
                onOpenPlayer: { playerPresentation.showFullPlayer() },
                onBrowseLibrary: { navMode = .library }
            )
        case .library:
            LibrarySidebar(selectedBookID: $selectedBookID)
        case .jobs:
            JobsListView()
        case .settings:
            SettingsView()
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

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        switch navMode {
        case .library:
            libraryDetailColumn
        default:
            Text("")
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
                .id("\(book.id)-\(chapterIndex)")
            } else if selectedChapterIndex == nil, let book = selectedBook {
                VStack(spacing: 24) {
                    ChapterListColumn(
                        book: book,
                        selectedChapterIndex: $selectedChapterIndex
                    )
                    Button {
                        MainReaderView.setCurrentlyReading(bookID: book.id)
                        navMode = .reader
                    } label: {
                        Label("Open in Reader", systemImage: "book.fill")
                            .frame(minHeight: 44)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 16)
                }
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
