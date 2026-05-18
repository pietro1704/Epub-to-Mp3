import SwiftUI

/// Top-level container. Branches on horizontal size class so iPad
/// landscape, iPad portrait wide, and macOS get a true multi-column
/// `NavigationSplitView`, while iPhone (compact) keeps the historical
/// `TabView` layout. Pre-iOS-16 / pre-macOS-13 fall through to the
/// tab layout regardless — those SDKs don't ship `NavigationSplitView`.
///
/// As of the Music/Spotify-style player slice, the Now Playing tab /
/// sidebar destination has been replaced by a **full-screen cover**
/// (`FullPlayerSheet`) that is presented by tapping the `MiniPlayerBar`.
/// Uses `.fullScreenCover` so it slides up from the bottom like
/// Spotify / Apple Music. Swipe-down dismisses it via a custom drag
/// gesture on the player view.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    /// iPhone Plus models report `.regular` horizontal in landscape but
    /// still ship a phone-class navigation surface — forcing a split
    /// view there breaks the toolbar. Combine size class with idiom on
    /// iOS so only true iPads (or macOS/Catalyst) get the split layout.
    #if os(iOS)
    private var useSplit: Bool {
        hSize == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }
    #else
    private var useSplit: Bool { hSize == .regular }
    #endif

    var body: some View {
        if useSplit {
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
            .compatFullScreenCover(isPresented: $playerPresentation.showingFullPlayer) {
                FullPlayerSheet()
                    .environmentObject(player)
                    .environmentObject(library)
            }
    }

    private var tabContent: some View {
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
            .miniPlayerInset(visible: showMiniPlayer, onTap: { playerPresentation.showFullPlayer() })
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(RootTab.library)

            CompatNavigationStack {
                SettingsView()
            }
            .miniPlayerInset(visible: showMiniPlayer, onTap: { playerPresentation.showFullPlayer() })
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
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

// MARK: - Mini player inset modifier

private struct MiniPlayerInsetModifier: ViewModifier {
    let visible: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if visible {
                MiniPlayerBar(onTap: onTap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("miniPlayer.tabBar")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: visible)
    }
}

extension View {
    func miniPlayerInset(visible: Bool, onTap: @escaping () -> Void) -> some View {
        modifier(MiniPlayerInsetModifier(visible: visible, onTap: onTap))
    }
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
