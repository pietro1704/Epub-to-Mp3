import SwiftUI

/// Top-level container. Branches on horizontal size class so iPad
/// landscape, iPad portrait wide, and macOS get a true multi-column
/// `NavigationSplitView`, while iPhone (compact) keeps the historical
/// `TabView` layout. Pre-iOS-16 / pre-macOS-13 fall through to the
/// tab layout regardless — those SDKs don't ship `NavigationSplitView`.
///
/// As of the Music/Spotify-style player slice, the Now Playing tab /
/// sidebar destination has been replaced by a **full-screen sheet**
/// (`FullPlayerSheet`) that is presented by tapping the `MiniPlayerBar`.
/// The sheet uses `.presentationDetents([.large])` on iOS 16+; on iOS
/// 15 it fills the screen (the system default). Swipe-down dismisses it.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        // macOS always reports regular; iPad portrait/landscape regular
        // for the master pane; iPhone is .compact except on a few Plus
        // models in landscape. Treating `.regular` as the split-view
        // signal mirrors what every Apple first-party reader does.
        if hSize == .regular {
            if #available(iOS 16, macOS 13, *) {
                SplitViewRoot()
            } else {
                TabRoot()
            }
        } else {
            TabRoot()
        }
    }
}

/// Tabs surfaced by the iPhone-compact root. The raw values double as
/// `TabView` selection tokens so the empty-state CTAs inside individual
/// tabs can flip to the matching tab without reaching across the view tree.
///
/// Tab order (Apple Books HIG pattern — no dedicated Now Playing tab):
///   0 reader   — default landing: full-screen EPUB reader
///   1 library  — book catalog
///   2 settings — preferences
enum RootTab: Int, Hashable {
    case reader
    case library
    case settings
}

/// The iPhone-compact / iOS 15 fallback layout.
///
/// Tab order:
///   0 Reader   — default landing: full-screen EPUB reader
///   1 Library  — navigable book catalog
///   2 Settings — preferences
///
/// `MiniPlayerBar` floats above the tab bar on every tab. Tap it to open
/// `FullPlayerSheet` (Apple Music style — sheet, not tab navigation).
struct TabRoot: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playerPresentation: PlayerPresentation

    @State private var selectedTab: RootTab = .reader

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when the mini-player should be shown: a book is active in the library.
    private var showMiniPlayer: Bool {
        guard let id = currentBookID, !id.isEmpty else { return false }
        return library.books.contains(where: { $0.id == id })
    }

    var body: some View {
        tabContent
            .sheet(isPresented: $playerPresentation.showingFullPlayer) {
                FullPlayerSheet()
                    .environmentObject(player)
                    .environmentObject(library)
            }
    }

    private var tabContent: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                CompatNavigationStack {
                    MainReaderView(
                        onOpenPlayer: { playerPresentation.showFullPlayer() },
                        onBrowseLibrary: { selectedTab = .library }
                    )
                }
                .tabItem { Label("Read", systemImage: "text.book.closed") }
                .tag(RootTab.reader)

                CompatNavigationStack {
                    LibraryView(onOpenBook: { selectedTab = .reader })
                }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)

                CompatNavigationStack {
                    SettingsView()
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let visible = showMiniPlayer && selectedTab != .reader
            if visible {
                MiniPlayerBar(onTap: { playerPresentation.showFullPlayer() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("miniPlayer.tabBar")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMiniPlayer)
    }
}

#Preview("Root") {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
        .environmentObject(BookmarkStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}

#Preview("Tab fallback") {
    TabRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        .environmentObject(PlayerPresentation())
        .environmentObject(BookmarkStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
