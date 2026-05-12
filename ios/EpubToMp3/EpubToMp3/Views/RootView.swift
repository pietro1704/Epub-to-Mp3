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
/// As of the Now-Playing landing-screen slice, both the tab and the
/// split-view layouts default to **Now Playing** — the player + reader
/// + download CTA for the user's most-recent audiobook. Library is one
/// tab / one sidebar destination away.
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
/// tabs (e.g. "Browse Library" on `NowPlayingView`) can flip to the
/// matching tab without reaching across the view tree.
enum RootTab: Int, Hashable {
    case nowPlaying
    case library
    case settings
}

/// The historical (iPhone-compact / iOS 15 fallback) layout. Pulled
/// out of `RootView` so the split-vs-tab branch is the only thing the
/// top-level sees.
///
/// Tab order mirrors Apple Podcasts / Books: "Now Playing" first as
/// the landing screen, Library second as the navigable catalog,
/// Settings last. Selecting a tab is reactive — the "Browse Library"
/// CTA on `NowPlayingView` writes back into `selectedTab` so the user
/// gets routed correctly without an extra dismiss.
struct TabRoot: View {
    @State private var selectedTab: RootTab = .nowPlaying

    var body: some View {
        TabView(selection: $selectedTab) {
            CompatNavigationStack {
                NowPlayingView(onBrowseLibrary: { selectedTab = .library })
            }
            .tabItem { Label("Now Playing", systemImage: "headphones.circle") }
            .tag(RootTab.nowPlaying)

            CompatNavigationStack {
                LibraryView()
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
}

#Preview("Root") {
    // RootView mounts LibraryView (Library tab) which reads
    // `@EnvironmentObject var library: LibraryStore` — provide all
    // three observable singletons or the canvas crashes the moment
    // SwiftUI tries to render the first tab.
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}

#Preview("Tab fallback") {
    TabRoot()
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        #if os(macOS)
        .environmentObject(SidecarManager())
        #endif
}
