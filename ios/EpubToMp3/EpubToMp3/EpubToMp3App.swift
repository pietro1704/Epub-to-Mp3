import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

@main
struct EpubToMp3App: App {
    @State private var settings = AppSettings()
    @State private var sidecar = SidecarManager()
    @State private var library = LibraryStore()

    init() {
        Self.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(sidecar)
                .environment(library)
                .task {
                    #if os(macOS)
                    await startSidecarIfNeeded()
                    #endif
                }
        }
    }

    #if os(macOS)
    /// Boot the embedded Python sidecar on first window appearance.
    /// Runs once per process — `SidecarManager.start()` is idempotent
    /// for the running case.
    ///
    /// Skipped under XCTest: when the unit-test bundle hosts the app,
    /// SwiftUI still mounts `WindowGroup` and would fire this task,
    /// hanging tests for 30s while the sidecar healthcheck fails.
    /// Detected via `XCTestConfigurationFilePath` env var which Xcode
    /// sets only inside `xcodebuild test` runs.
    @MainActor
    private func startSidecarIfNeeded() async {
        // Skip the sidecar boot under unit tests (xctest hosts the
        // app — without this guard SwiftUI would try to spin up the
        // Python server and hang the test bundle for 30 s).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        // Same story for the Xcode preview canvas. Xcode 26 sets
        // `XCODE_RUNNING_FOR_PLAYGROUNDS=1` (older Xcodes used the
        // legacy `XCODE_RUNNING_FOR_PREVIEWS=1`).
        let env = ProcessInfo.processInfo.environment
        if env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
            || env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        guard settings.useEmbeddedSidecar else { return }
        let result = await sidecar.start()
        if case .running(let url) = result {
            settings.sidecarURL = url
        }
    }
    #endif

    /// Configure `AVAudioSession` once on launch. Without this, MP3
    /// playback is silenced when the device is in silent mode and lock-
    /// screen controls do not surface.
    /// Required Info.plist key: `UIBackgroundModes` → `audio`.
    /// macOS doesn't have `AVAudioSession`; the entire body is gated to
    /// iOS / iPadOS where the type exists.
    private static func configureAudioSession() {
        #if os(iOS) && !targetEnvironment(simulator)
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
