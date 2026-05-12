import SwiftUI

/// Top-level container. Branches on horizontal size class so iPad
/// landscape, iPad portrait wide, and macOS get a true 3-column
/// `NavigationSplitView`, while iPhone (compact) keeps the historical
/// `TabView` layout. Pre-iOS-16 / pre-macOS-13 fall through to the
/// tab layout regardless — those SDKs don't ship `NavigationSplitView`.
///
/// The branch lives here (and not inside `SplitViewRoot`) so that the
/// availability check is co-located with the size-class check — it
/// reads top-down without jumping between files.
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

/// The historical (iPhone-compact / iOS 15 fallback) layout. Pulled
/// out of `RootView` so the split-vs-tab branch is the only thing the
/// top-level sees.
struct TabRoot: View {
    var body: some View {
        TabView {
            CompatNavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }

            CompatNavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
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
