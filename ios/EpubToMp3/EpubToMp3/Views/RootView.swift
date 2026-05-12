import SwiftUI

struct RootView: View {
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
