#if os(macOS)
import AppKit

/// The shipping window setup seam, also exercised with isolated native fixtures.
@MainActor
enum MacApplicationWindowSetup {
    static func make(settings: AppSettings, library: LibraryStore, player: AudioPlayer,
                     bookmarkStore: BookmarkStore, playerPresentation: PlayerPresentation,
                     timing: AppStartupTiming = .shared) -> (root: MacAppKitRootController, window: NSWindow) {
        timing.measure(.macWindowSetup) {
            let root = MacAppKitRootController(settings: settings, library: library, player: player,
                bookmarkStore: bookmarkStore, playerPresentation: playerPresentation)
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
            return (root, window)
        }
    }
}
#endif
