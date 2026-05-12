import SwiftUI

/// Top-level container. Branches on horizontal size class so iPad
/// landscape, iPad portrait wide, and macOS get a true multi-column
/// `NavigationSplitView`, while iPhone (compact) keeps the historical
/// `TabView` layout. Pre-iOS-16 / pre-macOS-13 fall through to the
/// tab layout regardless — those SDKs don't ship `NavigationSplitView`.
///
/// The branch lives here (and not inside `SplitViewRoot`) so that the
/// availability check is co-located with the size-class check — it
/// reads top-down without jumping between files.
///
/// As of the Reader-landing slice, both the tab and the split-view
/// layouts default to **Reader** — the full-screen book text in
/// Apple Books style. Now Playing is one tab / toolbar "Listen" tap
/// away. Library is one more tab beyond that.
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
/// tabs (e.g. "Browse Library" on `MainReaderView`) can flip to the
/// matching tab without reaching across the view tree.
///
/// Tab order (Apple Books / Apple Podcasts HIG pattern):
///   0 reader     — default landing: full-screen EPUB reader
///   1 nowPlaying — audio player (accessible via MiniPlayerBar tap)
///   2 library    — book catalog
///   3 settings   — preferences
enum RootTab: Int, Hashable {
    case reader
    case nowPlaying
    case library
    case settings
}

/// The iPhone-compact / iOS 15 fallback layout. Pulled out of `RootView`
/// so the split-vs-tab branch is the only thing the top-level sees.
///
/// Tab order (Apple Books / Apple Podcasts HIG pattern):
///   0 Reader     — default landing: full-screen EPUB reader (Apple Books style)
///   1 Now Playing — audio player, accessed via mini-player tap or this tab
///   2 Library    — navigable book catalog
///   3 Settings   — preferences
///
/// MiniPlayerBar floats above the tab bar on every tab except Now Playing.
/// Tap it to jump directly to the Now Playing tab (Apple Podcasts pattern).
struct TabRoot: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore
    /// Default to the Reader tab — that is the new landing screen.
    @State private var selectedTab: RootTab = .reader

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when the mini-player should be shown: a book is playing AND
    /// the user is not already on the Now Playing tab.
    private var showMiniPlayer: Bool {
        guard let id = currentBookID, !id.isEmpty else { return false }
        guard library.books.contains(where: { $0.id == id }) else { return false }
        return selectedTab != .nowPlaying
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Tab 0 — Reader (default landing)
                CompatNavigationStack {
                    MainReaderView(
                        onOpenPlayer: { selectedTab = .nowPlaying },
                        onBrowseLibrary: { selectedTab = .library }
                    )
                }
                .tabItem { Label("Read", systemImage: "text.book.closed") }
                .tag(RootTab.reader)

                // Tab 1 — Now Playing / audio player
                CompatNavigationStack {
                    NowPlayingView(onBrowseLibrary: { selectedTab = .library })
                }
                .tabItem { Label("Now Playing", systemImage: "headphones.circle") }
                .tag(RootTab.nowPlaying)

                // Tab 2 — Library
                CompatNavigationStack {
                    LibraryView()
                }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)

                // Tab 3 — Settings
                CompatNavigationStack {
                    SettingsView()
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
            }

            if showMiniPlayer {
                VStack(spacing: 0) {
                    MiniPlayerBar(onTap: { selectedTab = .nowPlaying })
                    // Spacer that matches the system tab bar height so
                    // the mini-player sits directly above it without
                    // overlapping. The tab bar is ~49pt + safe-area inset;
                    // Using a fixed 49pt footer is reliable across all iPhones.
                    Color.clear.frame(height: 49)
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMiniPlayer)
                .accessibilityIdentifier("miniPlayer.tabBar")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMiniPlayer)
    }
}

#Preview("Root") {
    // RootView mounts LibraryView (Library tab) which reads
    // `@EnvironmentObject var library: LibraryStore` — provide all
    // four observable singletons or the canvas crashes the moment
    // SwiftUI tries to render the first tab.
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}

#Preview("Tab fallback") {
    TabRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .environmentObject(AudioPlayer())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
