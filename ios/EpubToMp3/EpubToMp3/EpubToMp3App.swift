import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

@main
struct EpubToMp3App: App {
    @State private var settings = AppSettings()

    init() {
        Self.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }

    /// Configure `AVAudioSession` once on launch. Without this, MP3
    /// playback is silenced when the device is in silent mode and lock-
    /// screen controls do not surface.
    /// Required Info.plist key: `UIBackgroundModes` → `audio`.
    private static func configureAudioSession() {
        #if canImport(AVFoundation) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothA2DP, .allowAirPlay]
            )
            try session.setActive(true)
        } catch {
            // Non-fatal: simulator and unit-test contexts may reject this.
            #if DEBUG
            print("AVAudioSession configuration failed: \(error)")
            #endif
        }
        #endif
    }
}
