import Foundation

#if os(macOS)
import AppKit
#else
import AVFoundation
import UIKit
#endif

#if os(macOS)
private typealias PlatformApplicationDelegate = NSApplicationDelegate
#else
private typealias PlatformApplicationDelegate = UIApplicationDelegate
#endif

@MainActor
final class EpubToMp3App: NSObject, PlatformApplicationDelegate {
    let settings = AppSettings()
    let library: LibraryStore
    let player = AudioPlayer()
    let audioWarmup = AudioEngineWarmup()
    let playerPresentation = PlayerPresentation()
    let bookmarkStore = BookmarkStore()

    private var libraryImportTask: Task<Void, Never>?
#if os(iOS)
    private var libraryPersistenceWindow: UIBackgroundTaskIdentifier = .invalid
    private var libraryPersistenceGeneration: UUID?

    var libraryPersistenceBackgroundState: (generation: UUID, identifier: UIBackgroundTaskIdentifier)? {
        guard let generation = libraryPersistenceGeneration else { return nil }
        return (generation, libraryPersistenceWindow)
    }
#endif

    override init() {
        library = LibraryStore()
        super.init()
#if os(iOS)
        library.installUITestFixtureIfRequested()
        DevelopmentSeedBook.install(into: library)
        UITestPlaybackFixture.installIfRequested(library: library, player: player)
#endif
        ApplicationWidgetIntents.registerObserver()
    }

    /// An injected library bypasses launch fixtures and their real-storage writes.
    init(library: LibraryStore) {
        self.library = library
        super.init()
    }

#if os(macOS)
    // AppKit uses the explicit main.swift bootstrap. Retain the delegate before
    // entering the application loop so it remains alive for the full session.
    private static var macOSDelegate: EpubToMp3App?

    static func runApp() {
        let application = NSApplication.shared
        let delegate = EpubToMp3App()
        macOSDelegate = delegate
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.mainMenu = MacApplicationMenu.make(target: delegate)
        delegate.configureMainWindowIfNeeded()
        application.finishLaunching()
        application.run()
    }

    private var window: NSWindow?
    private var rootController: MacAppKitRootController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindowIfNeeded()
    }

#if os(macOS)
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }
#endif

    private func configureMainWindowIfNeeded() {
        guard window == nil else { return }
        let root = MacAppKitRootController(
            settings: settings,
            library: library,
            player: player,
            bookmarkStore: bookmarkStore,
            playerPresentation: playerPresentation
        )
        rootController = root
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        window.title = "Epub-to-Mp3"
        window.contentViewController = root
        root.configureWindowToolbar(window)
        // Pin the programmatic split view to the content view. Its intrinsic
        // width otherwise leaves an unused trailing region in NSWindow.
        if let contentView = window.contentView, contentView !== root.view {
            root.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                root.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                root.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                root.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                root.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        EpubToMp3WindowConfiguration.centerOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        activateRuntime()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleIncomingURL(url) }
    }

    @objc func importBooks(_ sender: Any?) {
        rootController?.importBooks(sender)
    }

    @objc func toggleNavigationSidebar(_ sender: Any?) {
        rootController?.toggleNavigationSidebar(sender)
    }

    @objc func showSettings(_ sender: Any?) { rootController?.showSettings(sender) }

    @objc func focusLibrarySearch(_ sender: Any?) {
        rootController?.focusLibrarySearch(sender)
    }

#else
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        library.installUITestFixtureIfRequested()
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetReaderPosition") {
            ReaderProgressStore.clearAll()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetActiveReader") {
            ReaderSessionState.setCurrentlyReading(bookID: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            // Each UI test must start at the deterministic library surface;
            // otherwise a previous reader or full-player presentation wins at launch.
            ReaderSessionState.setCurrentlyReading(bookID: nil)
            playerPresentation.dismissFullPlayer()
        }
        // The scene manifest always declares IOSSceneDelegate. It is the sole
        // owner of the visible window; creating a fallback UIWindow here races
        // the scene connection and unbalances root appearance transitions.
        return true
    }

    func makeIOSRootController() -> IOSRootContainerController {
        IOSRootContainerController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore
        )
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let isCarPlay = connectingSceneSession.role == .carTemplateApplication
        let configuration = UISceneConfiguration(
            name: isCarPlay ? "CarPlay" : "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        if isCarPlay {
            configuration.delegateClass = CarPlaySceneDelegate.self
        }
        return configuration
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleIncomingURL(url)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        activateRuntimeForScene()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        deactivateRuntimeForScene()
    }

    func activateRuntimeForScene() {
        activateRuntime()
    }

    func deactivateRuntimeForScene() {
        deactivateRuntime()
        guard libraryPersistenceWindow == .invalid else { return }
        let generation = UUID()
        libraryPersistenceGeneration = generation
        libraryPersistenceWindow = UIApplication.shared.beginBackgroundTask(withName: "Persist library") { [weak self] in
            Task { @MainActor [weak self] in self?.endLibraryPersistenceWindow(generation: generation) }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endLibraryPersistenceWindow(generation: generation) }
            do { try await self.library.flushPersistence() }
            catch { NSLog("Library background persistence failed: %@", error.localizedDescription) }
        }
    }

    func endLibraryPersistenceWindow(generation: UUID) {
        guard libraryPersistenceGeneration == generation else { return }
        let window = libraryPersistenceWindow
        libraryPersistenceWindow = .invalid
        libraryPersistenceGeneration = nil
        if window != .invalid { UIApplication.shared.endBackgroundTask(window) }
    }
#endif

#if os(macOS)
    func applicationDidBecomeActive(_ notification: Notification) {
        activateRuntime()
    }

    func applicationWillTerminate(_ notification: Notification) {
        player.persistResumePoint(force: true)
        do { try library.flushPersistenceSync() }
        catch { NSLog("Library termination persistence failed: %@", error.localizedDescription) }
    }
#else
    func applicationWillTerminate(_ application: UIApplication) {
        player.persistResumePoint(force: true)
        do { try library.flushPersistenceSync() }
        catch { NSLog("Library termination persistence failed: %@", error.localizedDescription) }
    }
#endif

    private func activateRuntime() {
        ApplicationWidgetIntents.bind(player: player)
        importPendingLibraryBooks()
        drainPendingIntent()
        ApplicationWidgetIntents.drainPending(player: player)
        WidgetDataSync.reloadAll()
        setIdleTimerDisabled(true)
        guard !Self.isRunningUnderXCTest() else { return }
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

    private func importPendingLibraryBooks() {
#if os(iOS)
        guard libraryImportTask == nil else { return }
        libraryImportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.libraryImportTask = nil }
            let shared = await SharedContainerImporter.drainAsync(into: self.library)
            for outcome in shared {
                if let error = outcome.error {
                    print("[ShareInbox] failed \(outcome.url.lastPathComponent): \(error)")
                }
            }
            let documents = await DocumentsBookImporter.importPendingAsync(into: self.library)
            for outcome in documents where outcome.error != nil {
                print("[DocumentsImport] failed \(outcome.url.lastPathComponent): \(outcome.error!)")
            }
        }
#endif
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            Task { [weak self] in
                guard let self else { return }
                if let book = try? await self.library.importBookAsync(from: url) {
                    UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
                }
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
        environment.keys.contains("XCTestConfigurationFilePath")
            || environment.keys.contains("XCTestSessionIdentifier")
            || environment.keys.contains("XCTestBundlePath")
            || classLookup("XCTest.XCTestCase") != nil
            || classLookup("XCTestCase") != nil
    }
}
