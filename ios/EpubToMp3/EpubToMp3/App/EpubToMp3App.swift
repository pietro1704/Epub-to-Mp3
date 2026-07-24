import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
private typealias PlatformApplicationDelegate = NSApplicationDelegate
enum EpubToMp3WindowConfiguration {
    static let macOSMinimumSize = CGSize(width: 1000, height: 700)
    static let macOSDefaultSize = CGSize(width: 1100, height: 760)
}
#else
private typealias PlatformApplicationDelegate = UIApplicationDelegate
#endif

@main
@MainActor
final class EpubToMp3App: NSObject, PlatformApplicationDelegate {
    let settings = AppSettings()
    let sidecar = SidecarManager()
    let library = LibraryStore()
    let player = AudioPlayer()
    let audioWarmup = AudioEngineWarmup()
    let playerPresentation = PlayerPresentation()
    let bookmarkStore = BookmarkStore()

    nonisolated(unsafe) private static var sharedPlayerForWidgetIntents: AudioPlayer?

    override init() {
        super.init()
        Self.registerWidgetIntentObserver()
    }

#if os(macOS)
    private var window: NSWindow?
    private var rootController: MacAppKitRootController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = MacAppKitRootController(
            settings: settings,
            library: library,
            player: player,
            bookmarkStore: bookmarkStore,
            sidecar: sidecar,
            playerPresentation: playerPresentation
        )
        rootController = root
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: EpubToMp3WindowConfiguration.macOSDefaultSize.width,
                height: EpubToMp3WindowConfiguration.macOSDefaultSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Epub-to-Mp3"
        window.minSize = EpubToMp3WindowConfiguration.macOSMinimumSize
        window.contentViewController = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        startSidecarIfNeeded()
        activateRuntime()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleIncomingURL(url) }
    }

    private func startSidecarIfNeeded() {
        guard settings.useEmbeddedSidecar, !Self.isRunningUnderXCTest() else { return }
        Task {
            let result = await sidecar.start()
            if case .running(let url) = result { settings.sidecarURL = url }
        }
    }
#else
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let root = IOSRootContainerController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Task { await audioWarmup.start() }
        activateRuntime()
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleIncomingURL(url)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        activateRuntime()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        deactivateRuntime()
    }
#endif

#if os(macOS)
    func applicationDidBecomeActive(_ notification: Notification) {
        activateRuntime()
    }

    func applicationWillTerminate(_ notification: Notification) {
        player.persistResumePoint(force: true)
    }
#else
    func applicationWillTerminate(_ application: UIApplication) {
        player.persistResumePoint(force: true)
    }
#endif

    private func activateRuntime() {
        Self.sharedPlayerForWidgetIntents = player
        drainSharedInbox()
        drainPendingIntent()
        drainWidgetIntents()
        WidgetDataSync.reloadAll()
        setIdleTimerDisabled(true)
        guard !Self.isRunningUnderXCTest() else { return }
        runCacheEviction()
        pruneOrphanBookmarks()
        pruneOrphanFulltextCache()
    }

    private func deactivateRuntime() {
        setIdleTimerDisabled(false)
        player.persistResumePoint(force: true)
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
#endif
    }

    private func drainSharedInbox() {
#if os(iOS)
        guard SharedContainerImporter.isAppGroupAvailable else { return }
        let outcomes = SharedContainerImporter.drain(into: library)
        for outcome in outcomes {
            if let error = outcome.error {
                print("[ShareInbox] failed \(outcome.url.lastPathComponent): \(error)")
            }
        }
#endif
    }

    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            if let book = try? library.importBook(from: url) {
                UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            }
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let bookID = components.queryItems?.first(where: { $0.name == "bookId" })?.value,
              library.books.contains(where: { $0.id == bookID }) else { return }
        UserDefaults.standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        if components.host == "player" {
            PlaybackBindingStore.setCurrentlyPlaying(bookID: bookID, chapterIndex: 0)
            playerPresentation.showFullPlayer()
        }
    }

    private func drainPendingIntent() {
        guard let bookID = UserDefaults.standard.string(forKey: "intent.pendingBookId") else { return }
        UserDefaults.standard.removeObject(forKey: "intent.pendingBookId")
        openBookById(bookID)
    }

    private func openBookById(_ bookID: String) {
        guard library.books.contains(where: { $0.id == bookID }) else { return }
        ReaderSessionState.setCurrentlyReading(bookID: bookID)
    }

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

    private static func registerWidgetIntentObserver() {
        guard !isRunningUnderXCTest() else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in EpubToMp3App.drainWidgetIntentsStatic() }
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

    private func runCacheEviction() {
        let budget = settings.offlineCacheBudgetBytes
        let ttl = settings.offlineCacheTTLSeconds
        var activeIDs: Set<String> = []
        if let jobID = player.snapshot?.jobId { activeIDs.insert(jobID) }
        let library = self.library
        Task.detached(priority: .background) {
            AudiobookCacheEviction.runEviction(
                budgetBytes: budget,
                ttlSeconds: ttl,
                activeJobIds: activeIDs
            )
            await MainActor.run {
                for id in AudiobookCacheEviction.staleOfflineBookIds(books: library.books) {
                    guard var book = library.books.first(where: { $0.id == id }) else { continue }
                    book.cachedOffline = false
                    library.update(book)
                }
            }
        }
    }

    private func pruneOrphanBookmarks() {
        _ = bookmarkStore.pruneOrphans(validBookIds: Set(library.books.map(\.id)))
    }

    private func pruneOrphanFulltextCache() {
        _ = LocalFulltextCache.pruneOrphans(validBookIds: Set(library.books.map(\.id)))
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
}
