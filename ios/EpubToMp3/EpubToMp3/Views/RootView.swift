import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                JobsListView()
            }
            .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
