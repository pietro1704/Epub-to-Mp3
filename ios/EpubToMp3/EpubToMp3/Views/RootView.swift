import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview("Root") {
    // RootView mounts LibraryView (Library tab) which reads
    // `@Environment(LibraryStore.self)` — provide all three
    // observable singletons or the canvas crashes the moment
    // SwiftUI tries to render the first tab.
    RootView()
        .environment(AppSettings())
        .environment(LibraryStore())
        #if os(macOS)
        .environment(SidecarManager())
        #endif
}
