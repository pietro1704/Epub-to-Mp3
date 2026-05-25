import SwiftUI

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
    @StateObject private var bookmarkStore = BookmarkStore()
    /// Single source of truth for the reader's current position.
    /// Replaces the three-UserDefaults-keys IPC pattern that wrote
    /// once per page turn into the prefs daemon — see
    /// `Services/ReaderCoordinator.swift`.
    @StateObject private var readerCoordinator = ReaderCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Audio session configured lazily on first playback (AudioPlayer)
        // to avoid the CoreAudio AddInstanceForFactory log on app launch.
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(sidecar)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(playerPresentation)
                .environmentObject(bookmarkStore)
                .environmentObject(readerCoordinator)
                .preferredColorScheme(settings.readerTheme.preferredColorScheme)
                .task {
                    #if os(macOS)
                    await startSidecarIfNeeded()
                    #endif
                    guard !Self.isRunningUnderXCTest() else { return }
                    // Run LRU+TTL eviction on every app launch (background priority).
                    runCacheEviction()
                }
                .task(priority: .utility) {
                    guard !Self.isRunningUnderXCTest() else { return }
                    #if os(iOS) || targetEnvironment(simulator)
                    do {
                        try await PythonRunner.shared.callAsync {
                            try PythonEmbed.shared.bootstrap()
                        }
                    } catch {
                        NSLog("[Prewarm] Python bootstrap failed: %@", "\(error)")
                    }
                    #endif
                }
                .compatOnChange(of: scenePhase) { phase in
                    if phase == .active {
                        guard !Self.isRunningUnderXCTest() else { return }
                        drainSharedInbox()
                        drainPendingIntent()
                        drainWidgetIntents()
                        WidgetDataSync.reloadAll()
                    } else if phase == .background {
                        // Flush the playback position to UserDefaults before
                        // the process is suspended so resume works correctly
                        // on a cold relaunch.
                        player.persistResumePoint(force: true)
                    }
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
        #if targetEnvironment(simulator)
        return
        #else
        guard SharedContainerImporter.isAppGroupAvailable else { return }
        let outcomes = SharedContainerImporter.drain(into: library)
        guard !outcomes.isEmpty else { return }
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
    ///   * The custom scheme `epubtomp3://` is triggered (widget,
    ///     App Intent, or external deep-link).
    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "epubtomp3" {
            handleDeepLink(url)
            return
        }
        guard url.isFileURL else { return }
        do {
            let book = try library.importBook(from: url)
            MainReaderView.setCurrentlyReading(bookID: book.id)
        } catch {
            #if DEBUG
            print("[onOpenURL] import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            #endif
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch components.host {
        case "open":
            if let bookId = components.queryItems?.first(where: { $0.name == "bookId" })?.value {
                openBookById(bookId)
            }
        case "player":
            if let bookId = components.queryItems?.first(where: { $0.name == "bookId" })?.value {
                openBookById(bookId)
                // Also set the player state so the full-player sheet
                // can pick up this book on foreground.
                NowPlayingView.setCurrentlyPlaying(bookID: bookId, chapterIndex: 0)
            }
        case "library":
            // No-op: the app opens to the library tab by default when
            // no book is selected. A future enhancement could push the
            // tab selection, but the current RootView routing handles it.
            break
        default:
            break
        }
    }

    /// Read and clear the trampoline key written by App Intents.
    private func drainPendingIntent() {
        guard let bookId = UserDefaults.standard.string(forKey: "intent.pendingBookId") else { return }
        UserDefaults.standard.removeObject(forKey: "intent.pendingBookId")
        openBookById(bookId)
    }

    private func openBookById(_ bookId: String) {
        guard library.books.contains(where: { $0.id == bookId }) else { return }
        MainReaderView.setCurrentlyReading(bookID: bookId)
    }

    /// Read and clear playback-control flags written by widget intents
    /// (App Group suite). The widget cannot call AudioPlayer directly,
    /// so it writes boolean flags that we drain here on every foreground.
    private func drainWidgetIntents() {
        guard let group = UserDefaults(suiteName: LibraryStore.appGroupID) else { return }

        if group.bool(forKey: "widget.intent.togglePlayPause") {
            group.removeObject(forKey: "widget.intent.togglePlayPause")
            player.togglePlayPause()
        }

        if group.bool(forKey: "widget.intent.skipForward30") {
            group.removeObject(forKey: "widget.intent.skipForward30")
            player.skipForward(seconds: 30)
        }
    }

    // MARK: Cache eviction

    /// Kick off the LRU+TTL eviction policy in the background.
    /// Active playback job is excluded so music is never interrupted.
    private func runCacheEviction() {
        let budgetBytes = settings.offlineCacheBudgetBytes
        let ttlSeconds  = settings.offlineCacheTTLSeconds
        // Collect active IDs: whatever the player is currently playing.
        var activeIds: Set<String> = []
        if let jobId = player.snapshot?.jobId { activeIds.insert(jobId) }
        Task.detached(priority: .background) {
            AudiobookCacheEviction.runEviction(
                budgetBytes: budgetBytes,
                ttlSeconds: ttlSeconds,
                activeJobIds: activeIds
            )
        }
    }

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
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
        if Self.isRunningUnderXCTest() {
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

    // Audio session configuration moved to AudioPlayer.ensureAudioSession()
    // to defer CoreAudio init (and its AddInstanceForFactory log) until
    // first playback.
}
