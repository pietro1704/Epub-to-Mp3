import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

@main
struct EpubToMp3App: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var sidecar = SidecarManager()
    @StateObject private var library = LibraryStore()
    /// Global shared AudioPlayer. Injected as @EnvironmentObject so
    /// MiniPlayerBar and FullPlayerSheet share the same AVQueuePlayer
    /// instance — transport controls on the mini-player affect the full
    /// player and vice-versa.
    @StateObject private var player = AudioPlayer()
    /// Controls the global full-player sheet presentation. Shared so any
    /// surface (MiniPlayerBar, deep link, keyboard shortcut) can open the
    /// full-screen player without passing callbacks through the view tree.
    @StateObject private var playerPresentation = PlayerPresentation()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(sidecar)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(playerPresentation)
                .task {
                    #if os(macOS)
                    await startSidecarIfNeeded()
                    #endif
                }
                .task { drainSharedInbox() }
                .compatOnChange(of: scenePhase) { phase in
                    if phase == .active { drainSharedInbox() }
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    /// Drain the App Group inbox into the LibraryStore. Triggered on
    /// every foreground transition so files dropped by the Share
    /// Extension surface immediately when the user comes back to the
    /// app. No-op when the inbox is empty.
    private func drainSharedInbox() {
        let outcomes = SharedContainerImporter.drain(into: library)
        guard !outcomes.isEmpty else { return }
        #if DEBUG
        for o in outcomes {
            if let err = o.error {
                print("[ShareInbox] failed \(o.url.lastPathComponent): \(err)")
            } else if let id = o.importedBookID {
                print("[ShareInbox] imported \(o.url.lastPathComponent) as \(id)")
            }
        }
        #endif
    }

    /// `.onOpenURL` is invoked when:
    ///   * The user taps a `.epub` / `.pdf` file in Files / Mail and
    ///     picks EpubToMp3 in "Open With".
    ///   * The custom scheme `epubtomp3://` is triggered (deeplink).
    /// We import the file URL directly into the library; opaque
    /// scheme URLs are ignored for now (the scheme reservation is
    /// kept for future Universal Links).
    private func handleIncomingURL(_ url: URL) {
        guard url.isFileURL else { return }
        do {
            _ = try library.importBook(from: url)
        } catch {
            #if DEBUG
            print("[onOpenURL] import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            #endif
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
        // If the child process dies later, clear the stale URL on
        // AppSettings so the rest of the app stops hammering the dead
        // loopback port — and try a single restart. Without this, the
        // user-visible symptom is hundreds of "Connection refused"
        // log lines to 127.0.0.1:NNNN until the app is force-quit.
        sidecar.onSidecarDied = { [weak settings, weak sidecar] in
            settings?.sidecarURL = nil
            guard let sidecar else { return }
            Task { @MainActor in
                let result = await sidecar.start()
                if case .running(let url) = result {
                    settings?.sidecarURL = url
                }
            }
        }
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
        // HIG long-form audio (Apple Books / Podcasts): `.playback` with
        // `.spokenAudio` and the long-form policy ducks other audio +
        // resumes after interruptions correctly. The previous form passed
        // both `mode` AND `options` to `setCategory(...)`, which can
        // return kAudio_ParamError (-50) on devices where the option set
        // conflicts with the policy. Use the three-argument variant that
        // takes a `RouteSharingPolicy` instead — that's the supported
        // long-form-audio API and matches what `MPNowPlayingInfoCenter`
        // expects.
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
            try session.setActive(true, options: [])
        } catch {
            // Fall back to the minimal form. `.playback` alone is enough
            // for background audio + lock-screen controls; we lose
            // long-form-audio policy niceties but the player still works.
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                #if DEBUG
                print("AVAudioSession configuration failed: \(error)")
                #endif
            }
        }
        #endif
    }
}
