import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
private typealias PlatformApplicationDelegate = NSApplicationDelegate
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
    let readerCoordinator = ReaderCoordinator()

#if os(macOS)
    private var window: NSWindow?
    private var rootController: MacAppKitRootController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = MacAppKitRootController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation
        )
        rootController = root
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Epub-to-Mp3"
        window.minSize = NSSize(width: 1000, height: 700)
        window.contentViewController = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        startSidecarIfNeeded()
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
    private var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let root = IOSRootContainerController(
            settings: settings,
            sidecar: sidecar,
            library: library,
            player: player,
            audioWarmup: audioWarmup,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore,
            readerCoordinator: readerCoordinator
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Task { await audioWarmup.start() }
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleIncomingURL(url)
        return true
    }
#endif

    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            if let book = try? library.importBook(from: url) {
                UserDefaults.standard.set(book.id, forKey: MainReaderView.currentlyReadingBookIDKey)
            }
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let bookID = components.queryItems?.first(where: { $0.name == "bookId" })?.value,
              library.books.contains(where: { $0.id == bookID }) else { return }
        UserDefaults.standard.set(bookID, forKey: MainReaderView.currentlyReadingBookIDKey)
        if components.host == "player" { playerPresentation.showFullPlayer() }
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
