#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

extension NativeResponsiveScreenTests {
#if os(iOS)
    func testSettingsRecycledCellsSpeakTheirCurrentVisibleContent() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = SettingsScreenController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
            diagnosticsSession: StreamingDiagnosticsSession())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let sections: [SettingsSection] = [.storage, .reader, .advanced, .runtime, .about]
        for section in sections.map(\.rawValue) {
            for row in 0..<controller.tableView(controller.tableView, numberOfRowsInSection: section) {
                let index = IndexPath(row: row, section: section)
                controller.tableView.scrollToRow(at: index, at: .middle, animated: false)
                controller.tableView.layoutIfNeeded()
                guard let cell = controller.tableView.cellForRow(at: index),
                      let content = cell.contentConfiguration as? UIListContentConfiguration,
                      let title = content.text, let spoken = cell.accessibilityLabel else { continue }
                XCTAssertTrue(spoken.contains(title), "Visible title '\(title)' must not retain old spoken label '\(spoken)'")
            }
        }
    }
#endif

#if os(iOS)
#else
    func testSettingsMenuDestinationReusesInstalledController() throws {
        UserDefaults.standard.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        root.loadViewIfNeeded()
        root.showSettings(nil)
        let first = try XCTUnwrap(childControllers(root).compactMap { $0 as? MacSettingsViewController }.first)
        root.showSettings(nil)
        XCTAssertTrue(childControllers(root).contains { $0 === first })
    }
#endif

#if os(iOS)
#else
    func testReaderAppearanceControlsHaveSpokenNames() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let reader = MacReaderViewController(library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        let button = try XCTUnwrap(descendants(reader.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "reader.settings.toggle" })
        button.performClick(nil)
        let views = NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
        for (identifier, key) in [("font", "reader.font"), ("theme", "reader.theme"),
                                  ("layout", "reader.layout"), ("columns", "reader.columns")] {
            let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "readerSettings.\(identifier)" })
            XCTAssertEqual(popup.accessibilityLabel(), L10n.string(key))
        }
        // Since #1147 size, margin and kerning are preset sliders.
        for (identifier, key) in [("fontSize", "settings.fontSize"), ("margin", "reader.margins"),
                                  ("kerning", "reader.kerning")] {
            let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }
                .first { $0.accessibilityIdentifier() == "readerSettings.\(identifier)" })
            XCTAssertEqual(slider.accessibilityLabel(), L10n.string(key))
        }
    }
#endif



#if os(iOS)
#else
    func testSettingsControlsFitResizedWindowAndLastActionCanScrollIntoView() throws {
        let controller = MacSettingsViewController(settings: AppSettings(defaults: defaults),
                                                   library: LibraryStore(defaults: defaults))
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("settings.clearAllDownloads"))
    }
#endif
}
#endif
