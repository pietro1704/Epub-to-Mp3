import SwiftUI

@main
struct EpubToMp3App: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}
