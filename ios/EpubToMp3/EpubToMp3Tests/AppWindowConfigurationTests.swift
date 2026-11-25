import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

final class AppWindowConfigurationTests: XCTestCase {
    #if os(macOS)
    func testMacOSDefaultWindowSizeLeavesRoomForSplitView() {
        let minimum = EpubToMp3WindowConfiguration.macOSMinimumSize
        let size = EpubToMp3WindowConfiguration.macOSDefaultSize

        XCTAssertGreaterThanOrEqual(minimum.width, 1000)
        XCTAssertGreaterThanOrEqual(minimum.height, 700)
        XCTAssertGreaterThanOrEqual(size.width, 1000)
        XCTAssertGreaterThanOrEqual(size.height, 700)
    }

    @MainActor
    func testShippingWindowOwnsItsNativeRootController() throws {
        let suite = "window-ownership.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey, "readerWarmBookIDs.v1"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let timing = AppStartupTiming(arguments: [])
        let setup = MacApplicationWindowSetup.make(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library", startupTiming: timing), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults), timing: timing)
        setup.window.isReleasedWhenClosed = false
        defer {
            LocalFulltextCache.cancelPrewarming()
            player.stop()
            setup.window.orderOut(nil); setup.window.contentViewController = nil; setup.window.close()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            NSApp.setActivationPolicy(policy)
        }
        XCTAssertTrue(setup.window.contentViewController === setup.root)
        XCTAssertTrue(setup.root.view.window === setup.window)
        XCTAssertEqual(setup.root.splitViewItems.count, 2)
    }

    /// MAC-WINDOW-ADAPT (mac-fullscreen-wrong.png): in full screen the content
    /// stayed ~1140 pt wide, centred between black bars. The shipping window
    /// must accept any size the system or the listener gives it, and the split
    /// view must fill it.
    @MainActor
    func testShippingWindowContentFillsAFullScreenSizedFrame() throws {
        let suite = "window-adapt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey, "readerWarmBookIDs.v1"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let timing = AppStartupTiming(arguments: [])
        let setup = MacApplicationWindowSetup.make(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library", startupTiming: timing), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults), timing: timing)
        setup.window.isReleasedWhenClosed = false
        defer {
            LocalFulltextCache.cancelPrewarming()
            player.stop()
            setup.window.orderOut(nil); setup.window.contentViewController = nil; setup.window.close()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            NSApp.setActivationPolicy(policy)
        }
        XCTAssertTrue(setup.window.collectionBehavior.contains(.fullScreenPrimary)
                      || setup.window.styleMask.contains(.resizable))
        for size in [NSSize(width: 1680, height: 1050), NSSize(width: 2560, height: 1440), NSSize(width: 1180, height: 760)] {
            setup.window.setFrame(NSRect(origin: .zero, size: size), display: true)
            setup.window.layoutIfNeeded()
            let content = try XCTUnwrap(setup.window.contentView)
            XCTAssertEqual(setup.window.frame.size, size, "The window must take the size it is given")
            XCTAssertLessThanOrEqual(setup.window.contentMinSize.width, size.width)
            XCTAssertEqual(content.frame.width, size.width, accuracy: 0.5)
            XCTAssertEqual(setup.root.view.frame.width, content.bounds.width, accuracy: 0.5,
                           "The split view must fill the window at \(size)")
            XCTAssertEqual(setup.root.splitView.frame.width, content.bounds.width, accuracy: 0.5)
            let detail = try XCTUnwrap(setup.root.splitViewItems.last?.viewController.view)
            XCTAssertEqual(detail.frame.maxX, setup.root.splitView.bounds.maxX, accuracy: 0.5,
                           "The detail pane must reach the trailing edge at \(size)")
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "mac-window-\(Int(size.width))x\(Int(size.height))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor
    func testProgrammaticWindowUsesExplicitGeometryWithoutArchivedRestoration() {
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        XCTAssertFalse(window.isRestorable)
        XCTAssertNil(window.restorationClass)
        XCTAssertEqual(window.minSize, EpubToMp3WindowConfiguration.macOSMinimumSize)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size,
                       EpubToMp3WindowConfiguration.macOSDefaultSize)
    }

    @MainActor
    func testDelegateRejectsAutomaticWindowArchivesWhileSupportingSecureState() throws {
        let suite = "window-restoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = EpubToMp3App(library: LibraryStore(defaults: defaults, defaultsKey: "library"))
        XCTAssertTrue(app.applicationSupportsSecureRestorableState(NSApplication.shared))
        XCTAssertFalse(app.applicationShouldSaveSecureApplicationState(NSApplication.shared))
        XCTAssertFalse(app.applicationShouldRestoreSecureApplicationState(NSApplication.shared))
    }
    #endif
}
