#if os(macOS)
import AppKit

/// The shipping window setup seam, also exercised with isolated native fixtures.
@MainActor
enum MacApplicationWindowSetup {
    static func make(settings: AppSettings, library: LibraryStore, player: AudioPlayer,
                     bookmarkStore: BookmarkStore, playerPresentation: PlayerPresentation,
                     timing: AppStartupTiming = .shared) -> (root: MacAppKitRootController, window: NSWindow) {
        timing.measure(.macWindowSetup) {
            applyWindowingPolicy()
            let root = MacAppKitRootController(settings: settings, library: library, player: player,
                bookmarkStore: bookmarkStore, playerPresentation: playerPresentation)
            let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
            window.title = "Epub-to-Mp3"
            window.contentViewController = root
            root.configureWindowToolbar(window)
            keepDefaultContentBelowToolbar(window)
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
            return (root, window)
        }
    }

    /// Full-size content makes the window frame equal to the content rect, so
    /// grow it by the titlebar/toolbar height: the usable area below the toolbar
    /// keeps the default size it had before the content extended under it.
    private static func keepDefaultContentBelowToolbar(_ window: NSWindow) {
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        guard titlebarHeight > 0 else { return }
        let size = EpubToMp3WindowConfiguration.macOSDefaultSize
        window.setContentSize(NSSize(width: size.width, height: size.height + titlebarHeight))
    }

    /// The app has one main window. Opting out of automatic tabbing removes
    /// AppKit's New Tab (Cmd+T), Show Tab Bar, Show All Tabs and Merge All
    /// Windows commands. `runApp` applies it before the main menu exists; the
    /// window seam reasserts it (idempotent) for every window it builds.
    static func applyWindowingPolicy() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// AppKit's reopen request (Dock click, Finder relaunch). Returning false
    /// tells AppKit the request was handled, so it never creates another window.
    static func handleReopen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return reopen(window)
    }

    /// Re-shows the single main window, including after Cmd+W or minimize.
    @discardableResult
    static func reopen(_ window: NSWindow) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}
#endif
