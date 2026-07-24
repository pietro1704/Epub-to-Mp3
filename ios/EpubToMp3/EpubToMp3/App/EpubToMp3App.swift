import SwiftUI
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum EpubToMp3WindowConfiguration {
    #if os(macOS)
    /// The split-view/sidebar needs a real desktop canvas on first launch.
    /// Without a minimum content size, WindowGroup can derive a tiny
    /// intrinsic window from the overlay-only content during restoration.
    static let macOSMinimumSize = CGSize(width: 1000, height: 700)
    static let macOSDefaultSize = CGSize(width: 1100, height: 760)
    static let macOSWindowConfigurationAttemptDelays: [TimeInterval] = [
        0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3
    ]
    #endif
}

#if os(macOS)
private enum MacWindowBootstrap {
    static func schedule() {
        for delay in EpubToMp3WindowConfiguration.macOSWindowConfigurationAttemptDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                configure()
            }
        }
    }

    private static func configure() {
        let app = NSApplication.shared
        guard let window = app.windows.first else { return }
        let size = EpubToMp3WindowConfiguration.macOSDefaultSize
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.minSize = EpubToMp3WindowConfiguration.macOSMinimumSize
        if window.frame.width < size.width || window.frame.height < size.height {
            window.setFrame(frame, display: true, animate: false)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }
}
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
    @StateObject private var audioWarmup = AudioEngineWarmup()
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
        Self.registerWidgetIntentObserver()
        #if os(macOS)
        MacWindowBootstrap.schedule()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            appWindowContent
        }
        .commands { appCommands }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(sidecar)
        }
        #endif
    }

    /// HIG macOS Menus: transport controls belong in the menu bar, not
    /// only on-screen buttons — Space/⌘←/⌘→ match the Apple Music /
    /// Podcasts convention. `.commands` also surfaces these as discoverable
    /// hardware-keyboard shortcuts on iPad, so it isn't macOS-gated.
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("library.addBook")) {
                #if os(macOS)
                importBookViaOpenPanel()
                #endif
            }
            .keyboardShortcut("o", modifiers: .command)
            #if !os(macOS)
            .disabled(true)
            #endif
        }
        CommandMenu(L10n.string("menu.playback")) {
            Button(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play")) {
                player.togglePlayPause()
            }
            .keyboardShortcut(" ", modifiers: [])
            Divider()
            Button(L10n.string("player.nextChapter")) {
                player.nextChapter()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            Button(L10n.string("player.previousChapter")) {
                player.previousChapter()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }

    #if os(macOS)
    /// Menu-bar equivalent of `LibraryView`'s `fileImporter` — same
    /// accepted types, but driven from `NSOpenPanel` since `.commands`
    /// actions run outside any specific view's SwiftUI state.
    private func importBookViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = try? library.importBook(from: url)
        }
    }
    #endif

    private var appWindowContent: some View {
        RootView()
            #if os(macOS)
            .frame(
                minWidth: EpubToMp3WindowConfiguration.macOSMinimumSize.width,
                minHeight: EpubToMp3WindowConfiguration.macOSMinimumSize.height
            )
            #endif
            .environmentObject(settings)
            .environmentObject(sidecar)
            .environmentObject(library)
            .environmentObject(player)
            .environmentObject(player.playbackClock)
            .environmentObject(audioWarmup)
            .environmentObject(playerPresentation)
            .environmentObject(bookmarkStore)
            .environmentObject(readerCoordinator)
            .preferredColorScheme(settings.readerTheme.preferredColorScheme)
            .task {
                // Publish this scene's player/settings so the Darwin
                // notification callback (no captured context — it's a
                // bare C function pointer) can reach the running
                // instances without a full singleton refactor.
                Self.sharedPlayerForWidgetIntents = player
                drainWidgetIntents()
                #if os(macOS)
                await startSidecarIfNeeded()
                #endif
                setIdleTimerDisabled(true)
                guard !Self.isRunningUnderXCTest() else { return }
                // Run LRU+TTL eviction on every app launch (background priority).
                runCacheEviction()
                // One-shot prune of orphan bookmarks from pre-cascade
                // builds. Mirrors the Flutter slice-42 fix so existing
                // installs that already removed a book before
                // the cascade landed still drop the dangling entries.
                pruneOrphanBookmarks()
                // Slice 47: same one-shot for the on-disk EPUB
                // fulltext cache. Re-importing the same file would
                // otherwise resurrect stale reader text from a
                // pre-cascade install (bookId is SHA-256 of file
                // bytes).
                pruneOrphanFulltextCache()
            }
            .task(priority: .utility) {
                guard !Self.isRunningUnderXCTest() else { return }
                #if os(iOS) || targetEnvironment(simulator)
                await audioWarmup.start()
                #endif
            }
            .compatOnChange(of: scenePhase) { phase in
                if phase == .active {
                    setIdleTimerDisabled(true)
                    guard !Self.isRunningUnderXCTest() else { return }
                    drainSharedInbox()
                    drainPendingIntent()
                    drainWidgetIntents()
                    WidgetDataSync.reloadAll()
                } else if phase == .background {
                    setIdleTimerDisabled(false)
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

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS) || targetEnvironment(simulator)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
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
                PlaybackBindingStore.setCurrentlyPlaying(bookID: bookId, chapterIndex: 0)
                // Actually navigate to the player UI — without this the
                // widget tap only opened the app to the Library/reader
                // landing screen and never presented the full player.
                playerPresentation.showFullPlayer()
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
    /// so it writes boolean flags that we drain here — both on every
    /// foreground transition AND immediately via a Darwin notification
    /// (see `registerWidgetIntentObserver`) so a tap on the widget's
    /// play/pause button works even while the app is merely backgrounded.
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

    // MARK: - Widget intent Darwin notification bridge

    /// Weak-ish static hook so the Darwin notification C callback (which
    /// cannot capture `self`) can reach the live `AudioPlayer` instance.
    /// Set once per scene mount in the `.task` above. `nonisolated(unsafe)`
    /// per this project's documented pattern for statics accessed from a
    /// non-isolated C callback — writes happen on the main actor at scene
    /// mount, reads happen from the Darwin callback (also funneled back to
    /// the main actor before touching the player).
    nonisolated(unsafe) private static var sharedPlayerForWidgetIntents: AudioPlayer?

    /// Register a Darwin notification observer so widget-button taps are
    /// drained immediately, instead of waiting for a `scenePhase` change to
    /// `.active`. The app declares the `audio` UIBackgroundMode, so it can
    /// legitimately still be running (not suspended) while backgrounded
    /// during playback — this observer fires in that state too.
    private static func registerWidgetIntentObserver() {
        guard !isRunningUnderXCTest() else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    EpubToMp3App.drainWidgetIntentsStatic()
                }
            },
            "com.pietrocode.epubtomp3.widgetIntent" as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private static func drainWidgetIntentsStatic() {
        guard let player = sharedPlayerForWidgetIntents,
              let group = UserDefaults(suiteName: LibraryStore.appGroupID) else { return }

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
        let library = self.library
        Task.detached(priority: .background) {
            AudiobookCacheEviction.runEviction(
                budgetBytes: budgetBytes,
                ttlSeconds: ttlSeconds,
                activeJobIds: activeIds
            )
            // Eviction deletes Audiobooks/<jobId>/ wholesale but knows
            // nothing about the library — reconcile `cachedOffline` so
            // evicted books stop advertising "offline ready".
            await MainActor.run {
                let stale = AudiobookCacheEviction.staleOfflineBookIds(books: library.books)
                for id in stale {
                    guard var book = library.books.first(where: { $0.id == id }) else { continue }
                    book.cachedOffline = false
                    library.update(book)
                }
            }
        }
    }

    /// Walk the live library and ask BookmarkStore to drop any entry
    /// whose `bookId` no longer maps to a book. Silent no-op when the
    /// store is already clean.
    private func pruneOrphanBookmarks() {
        let valid = Set(library.books.map(\.id))
        _ = bookmarkStore.pruneOrphans(validBookIds: valid)
    }

    /// Drop any on-disk fulltext payload whose bookId no longer maps to
    /// a live library entry. Silent no-op when the cache is already
    /// clean.
    private func pruneOrphanFulltextCache() {
        let valid = Set(library.books.map(\.id))
        _ = LocalFulltextCache.pruneOrphans(validBookIds: valid)
    }

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
            || classLookup("XCTest.XCTestCase") != nil
            || classLookup("XCTestCase") != nil
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

@MainActor
final class AudioEngineWarmup: ObservableObject {
    enum State: Equatable {
        case idle
        case warming
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String = ""

    private var task: Task<Bool, Never>?
    private let warmupTimeoutSeconds: UInt64 = 20

    var isVisible: Bool {
        switch state {
        case .warming, .failed:
            return true
        case .idle, .ready:
            return false
        }
    }

    var stateLabel: String {
        switch state {
        case .idle: return L10n.string("audioWarmup.state.idle")
        case .warming: return L10n.string("audioWarmup.state.loading")
        case .ready: return L10n.string("audioWarmup.state.ready")
        case .failed: return L10n.string("audioWarmup.state.failed")
        }
    }

    var progressLabel: String {
        "\(Int((progress * 100).rounded()))%"
    }

    @discardableResult
    func start() async -> Bool {
        if case .ready = state { return true }
        if let task { return await task.value }

        state = .warming
        progress = 0.08
        message = L10n.string("audioWarmup.starting")

        let newTask = Task<Bool, Never> {
            #if os(iOS) || targetEnvironment(simulator)
            await MainActor.run {
                self.progress = 0.35
                self.message = L10n.string("audioWarmup.loading")
            }
            await Task.yield()
            await MainActor.run {
                self.progress = 1.0
                self.message = L10n.string("audioWarmup.ready")
                self.state = .ready
                self.task = nil
            }
            return true
            #else
            await MainActor.run {
                self.progress = 1.0
                self.message = L10n.string("audioWarmup.ready")
                self.state = .ready
                self.task = nil
            }
            return true
            #endif
        }
        task = newTask
        return await newTask.value
    }

    func waitUntilReady() async -> Bool {
        if case .ready = state { return true }
        return await start()
    }
}
