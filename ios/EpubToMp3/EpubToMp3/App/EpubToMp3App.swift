import Foundation

#if os(macOS)
import AppKit
#else
import AVFoundation
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

@MainActor
final class EpubToMp3App: NSObject, PlatformApplicationDelegate {
    let settings = AppSettings()
    let library = LibraryStore()
    let player = AudioPlayer()
    let audioWarmup = AudioEngineWarmup()
    let playerPresentation = PlayerPresentation()
    let bookmarkStore = BookmarkStore()

    private static var sharedPlayerForWidgetIntents: AudioPlayer?

    override init() {
        super.init()
#if os(iOS)
        library.installUITestFixtureIfRequested()
        library.installDevelopmentSeedBookIfRequested()
        installUITestPlaybackFixtureIfRequested()
#endif
        Self.registerWidgetIntentObserver()
    }

#if os(iOS)
    private func installUITestPlaybackFixtureIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestPlaybackFixture") else { return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-playback.wav")
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate / 2)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = Double(index) / Double(sampleRate) * 2 * .pi * 440
            var sample = Int16(sin(phase) * 2_000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(sampleRate, to: &wav)
        appendLittleEndian(sampleRate * 2, to: &wav)
        appendLittleEndian(UInt16(2), to: &wav)
        appendLittleEndian(UInt16(16), to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        try? wav.write(to: url, options: .atomic)

        let chapter = JobSnapshot.Chapter(
            index: 0, name: "UI Test Chapter", status: "completed",
            downloadUrl: url.absoluteString, chars: 100, charsProcessed: 100,
            progressRatio: 1, durationSeconds: 0.5, startedAt: nil, completedAt: nil
        )
        let snapshot = JobSnapshot(
            jobId: "ui-test-playback", state: "finished", bookTitle: "UI Test Book",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture",
            voice: nil, language: "en", progressPercent: 100, chaptersTotal: 1,
            chaptersCompleted: 1, chapterProgress: [chapter], outputs: nil,
            logUrl: nil, error: nil, lastActivityAt: nil
        )
        let fixtureBookID = library.books.first?.id ?? "ui-test-book"
        PlaybackBindingStore.setCurrentlyPlaying(bookID: fixtureBookID, chapterIndex: 0)
        player.play(snapshot: snapshot)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
#endif

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
        application.mainMenu = makeMainMenu(target: delegate)
        delegate.configureMainWindowIfNeeded()
        application.finishLaunching()
        application.run()
    }

    static func makeMainMenu(target: EpubToMp3App? = nil) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: L10n.string("app.name"))
        let about = NSMenuItem(
            title: L10n.string("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApplication.shared
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.string("menu.quitApp", L10n.string("app.name")),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: L10n.string("menu.file"))
        let importBook = NSMenuItem(
            title: L10n.string("menu.importBook"),
            action: #selector(EpubToMp3App.importBooks(_:)),
            keyEquivalent: "o"
        )
        importBook.target = target
        fileMenu.addItem(importBook)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            NSMenuItem(
                title: L10n.string("common.close"),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenu = NSMenu(title: L10n.string("menu.edit"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenu = NSMenu(title: L10n.string("menu.view"))
        let toggleSidebar = NSMenuItem(
            title: L10n.string("nav.toggleSidebar"),
            action: #selector(EpubToMp3App.toggleNavigationSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        toggleSidebar.target = target
        viewMenu.addItem(toggleSidebar)
        let searchLibrary = NSMenuItem(
            title: L10n.string("menu.searchLibrary"),
            action: #selector(EpubToMp3App.focusLibrarySearch(_:)),
            keyEquivalent: "f"
        )
        searchLibrary.target = target
        viewMenu.addItem(searchLibrary)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenu = NSMenu(title: L10n.string("menu.window"))
        windowMenu.addItem(
            NSMenuItem(
                title: L10n.string("menu.minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(NSMenuItem(title: L10n.string("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: L10n.string("menu.help"))
        let aboutHelp = NSMenuItem(
            title: L10n.string("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutHelp.target = NSApplication.shared
        helpMenu.addItem(aboutHelp)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        return mainMenu
    }

    private var window: NSWindow?
    private var rootController: MacAppKitRootController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindowIfNeeded()
    }

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
        centerWindowOnActiveScreen(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        bootstrapEmbeddedRuntime()
        activateRuntime()
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        // NSScreen.main can refer to a stale virtual display after a monitor
        // disconnect. The first screen is AppKit's primary display; clamp
        // the calculated frame to its visible area so a new window remains
        // reachable even when another display is arranged above it.
        let screen = NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleIncomingURL(url) }
    }

    @objc private func importBooks(_ sender: Any?) {
        rootController?.importBooks(sender)
    }

    @objc private func toggleNavigationSidebar(_ sender: Any?) {
        rootController?.toggleNavigationSidebar(sender)
    }

    @objc private func focusLibrarySearch(_ sender: Any?) {
        rootController?.focusLibrarySearch(sender)
    }

    private func bootstrapEmbeddedRuntime() {
        guard !Self.isRunningUnderXCTest() else { return }
        // CPython must be initialized on the same dedicated thread that
        // later accesses PythonKit. Initializing from a Swift concurrency
        // task makes the first EPUB parse run on a different thread and can
        // crash inside `_PyObject_Malloc`.
        PythonRunner.shared.async {
            do {
                try PythonEmbed.shared.bootstrap()
            } catch {
                print("[EmbeddedRuntime] bootstrap failed: \(error)")
            }
        }
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
        Task { await audioWarmup.start() }
        EmbeddedConversionCoordinator.resumePendingWork(
            library: library,
            settings: settings,
            player: player
        )
        activateRuntime()
    }

    func deactivateRuntimeForScene() {
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
        importDocumentsBooks()
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

    private func importDocumentsBooks() {
#if os(iOS)
        let outcomes = DocumentsBookImporter.importPending(into: library)
        for outcome in outcomes where outcome.error != nil {
            print("[DocumentsImport] failed \(outcome.url.lastPathComponent): \(outcome.error!)")
        }
#endif
    }

    func handleIncomingURL(_ url: URL) {
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
            player.skipForward()
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
            player.skipForward()
        }
    }

    private func runCacheEviction() {
        let budget = LocalAudioArtifactStore.temporaryCacheBudgetBytes()
        Task {
            _ = try? await LocalAudioArtifactStore.shared.evictTemporaryAudio(toMaximumBytes: budget)
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
        environment.keys.contains("XCTestConfigurationFilePath")
            || environment.keys.contains("XCTestSessionIdentifier")
            || environment.keys.contains("XCTestBundlePath")
            || classLookup("XCTest.XCTestCase") != nil
            || classLookup("XCTestCase") != nil
    }
}
