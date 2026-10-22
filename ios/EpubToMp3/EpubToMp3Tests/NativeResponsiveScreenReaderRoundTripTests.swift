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
#else
    func testLiveMacWindowSettingsAndLOTRPageRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["EPUBTOMP3_RUN_SEEDED_LOTR_JOURNEY"] == "1" else {
            throw XCTSkip("Seeded LOTR visible journey requires explicit opt-in and seeded book identity.")
        }
        let seededBookID = try XCTUnwrap(ProcessInfo.processInfo.environment["EPUBTOMP3_SEEDED_LOTR_BOOK_ID"])
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, "readerProgress.v1", "library.books.v1",
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        let libraryDefaults = UserDefaults(suiteName: LibraryStore.appGroupID)
        let savedLibrary = libraryDefaults?.object(forKey: "library.books.v1")
        let widgetState = Dictionary(uniqueKeysWithValues: widgetKeys.map { ($0, libraryDefaults?.object(forKey: $0)) })
        // The XCTest bootstrap deliberately starts only NSApplication's loop.
        // Exercise the shipping delegate's actual window factory in that process.
        let originalDelegate = NSApp.delegate
        let originalMenu = NSApp.mainMenu
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let application = EpubToMp3App()
        NSApp.delegate = application
        NSApp.mainMenu = MacApplicationMenu.make(target: application)
        application.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            application.player.stop()
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) {
                window.isReleasedWhenClosed = false
                window.close()
            }
            NSApp.delegate = originalDelegate
            NSApp.mainMenu = originalMenu
            // Startup, reader detachment and player shutdown may all write preferences.
            // Restore only after every owned lifecycle callback has completed.
            for key in keys { restore(saved[key] ?? nil, key: key, defaults: .standard) }
            if let libraryDefaults {
                restore(savedLibrary, key: "library.books.v1", defaults: libraryDefaults)
                for key in widgetKeys { restore(widgetState[key] ?? nil, key: key, defaults: libraryDefaults) }
            }
        }
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.contentViewController is MacAppKitRootController && $0.isVisible
        }, "The executable app's actual visible root window must be running.")
        let root = try XCTUnwrap(window.contentViewController as? MacAppKitRootController)
        let originalFrame = window.frame
        let report = FileManager.default.temporaryDirectory
            .appendingPathComponent("epubtomp3-live-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        defer {
            // Detaching the reader persists its final viewport before restoring the original preferences.
            root.focusLibrarySearch(nil)
            window.setFrame(originalFrame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        root.showSettings(nil)
        let settings = try XCTUnwrap(childControllers(root).compactMap { $0 as? MacSettingsViewController }.first)
        for size in [NSSize(width: 1000, height: 700), NSSize(width: 1250, height: 850)] {
            window.setContentSize(size)
            root.view.layoutSubtreeIfNeeded()
            let popups = descendants(settings.view).compactMap { $0 as? NSPopUpButton }
            XCTAssertGreaterThanOrEqual(popups.count, 4)
            let primary = try XCTUnwrap(popups.first { $0.accessibilityIdentifier() == "settings.tts.primary" })
            let secondary = try XCTUnwrap(popups.first { $0.accessibilityIdentifier() == "settings.tts.secondary" })
            let menu = try XCTUnwrap(secondary.menu)
            menu.update()
            XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: try XCTUnwrap(primary.titleOfSelectedItem))).isEnabled)
            XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: L10n.string("settings.noSecondary"))).isEnabled)
            for popup in popups {
                XCTAssertGreaterThan(popup.bounds.height, 0)
                XCTAssertTrue(window.contentView!.bounds.insetBy(dx: -1, dy: -1)
                    .contains(popup.convert(popup.bounds, to: window.contentView)),
                    "The installed Settings control must fit the real window: \(popup.accessibilityLabel() ?? popup.title)")
            }
            try captureLiveWindow(window, to: report.appendingPathComponent("settings-\(Int(size.width)).png"))
        }
        root.focusLibrarySearch(nil)
        root.view.layoutSubtreeIfNeeded()
        let libraryButtons = descendants(root.view).compactMap { $0 as? NSButton }
        let book = try XCTUnwrap(libraryButtons.first { button in
            let identifier: String? = button.accessibilityIdentifier()
            return identifier == "library.book.open.\(seededBookID)"
        }, "The actual library must contain the existing imported LOTR book.")
        book.performClick(nil)
        let reader = try XCTUnwrap(childControllers(root).compactMap { $0 as? MacReaderViewController }.first)
        let deadline = Date().addingTimeInterval(30)
        var text: NSTextView?
        while Date() < deadline {
            root.view.layoutSubtreeIfNeeded()
            text = descendants(reader.view).compactMap { $0 as? NSTextView }.first {
                $0.accessibilityIdentifier() == "reader.content" && !$0.string.isEmpty
            }
            let loading = descendants(reader.view).first { $0.accessibilityIdentifier() == "reader.loadingOverlay" }
            if text != nil && loading?.isHidden == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertLessThan(Date(), deadline, "The actual reader must finish restoring its saved location.")
        let document = try XCTUnwrap(text, "The real imported book must render.")
        let scroll = try XCTUnwrap(document.enclosingScrollView)
        window.makeFirstResponder(document)
        // Stay inside one real chapter so a forward/back pair restores the exact raw viewport offset.
        let maximum = max(0, document.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(maximum, scroll.contentView.bounds.height, "LOTR must expose a multi-page chapter.")
        let originalOffset = scroll.contentView.bounds.origin
        let startingOffset = NSPoint(x: originalOffset.x, y: min(originalOffset.y, maximum * 0.5))
        scroll.contentView.scroll(to: startingOffset)
        scroll.reflectScrolledClipView(scroll.contentView)
        defer {
            scroll.contentView.scroll(to: originalOffset)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try captureLiveWindow(window, to: report.appendingPathComponent("reader-before.png"))
        func sendArrow(_ keyCode: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        try sendArrow(124)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, startingOffset.y, "Actual right-arrow must advance the reader.")
        try captureLiveWindow(window, to: report.appendingPathComponent("reader-forward.png"))
        try sendArrow(123)
        XCTAssertEqual(scroll.contentView.bounds.minY, startingOffset.y, accuracy: 1,
                       "Actual left-arrow must restore the same viewport.")
        try captureLiveWindow(window, to: report.appendingPathComponent("reader-restored.png"))
        print("Live Mac app evidence: \(report.path)")
    }
#endif
}
#endif
