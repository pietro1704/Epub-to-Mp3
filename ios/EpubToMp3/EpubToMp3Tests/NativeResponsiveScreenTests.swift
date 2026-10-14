#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class NativeResponsiveScreenTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedStandard: [String: Any] = [:]
    private var savedWidget: [String: Any] = [:]
    private let standardKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                                ReaderSessionState.currentlyReadingBookIDKey]
    private let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                              "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                              "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                              "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]

    override func setUp() {
        super.setUp()
        suiteName = "responsive-screens-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        for key in standardKeys { savedStandard[key] = UserDefaults.standard.object(forKey: key) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        for key in widgetKeys { savedWidget[key] = widget?.object(forKey: key) }
    }

    override func tearDown() {
        for key in standardKeys { restore(savedStandard[key], key: key, defaults: .standard) }
        if let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID) {
            for key in widgetKeys { restore(savedWidget[key], key: key, defaults: widget) }
        }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private var book: BookEntity {
        BookEntity(id: suiteName, title: "A long book title that must remain readable on a compact screen",
                   author: "An author with a long descriptive name", bookmark: Data(),
                   displayFilename: "synthetic.epub", addedAt: Date(timeIntervalSince1970: 0))
    }

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
        for section in [4, 3, 5, 0, 6] {
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

    func testLibraryTilesReserveEnoughHeightForAccessibilityMetadata() throws {
        let controller = LibraryGridController(metrics: .init())
        let host = UIViewController()
        host.addChild(controller)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
                                       forChild: controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.frame = host.view.bounds
        controller.apply(model: LibraryGridModel(books: [book], selectedTag: nil, searchQuery: "", sortMode: .title), animated: false)
        controller.view.layoutIfNeeded()
        controller.collectionView.layoutIfNeeded()
        let cell = try XCTUnwrap(controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        for label in descendants(cell).compactMap({ $0 as? UILabel }) where !label.isHidden {
            XCTAssertGreaterThan(label.font.pointSize, 30, "The runtime fixture must really use accessibility text sizes")
            let expected = min(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height,
                               label.font.lineHeight * CGFloat(label.numberOfLines))
            XCTAssertGreaterThanOrEqual(label.bounds.height, expected - 1, "Book metadata must not lose lines at large text sizes")
        }
    }

    func testExpandedPlayerControlsRemainReachableWithLargeTextAndShortViewport() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320)] {
            var displayedBook = book
            displayedBook.title = "Book"
            displayedBook.bookmark = Data([1])
            displayedBook.author = "An author whose complete name must stay visible in the expanded player"
            defaults.set(try JSONEncoder().encode([displayedBook]), forKey: "library.books.v1")
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            defer { player.stop() }
            UserDefaults.standard.set(displayedBook.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            UserDefaults.standard.set(displayedBook.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
            let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
                library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
                settings: AppSettings(defaults: defaults))
            let host = UIViewController()
            host.addChild(controller)
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
                                            forChild: controller)
            host.view.addSubview(controller.view)
            controller.didMove(toParent: host)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            // Exercise a live Dynamic Type transition after UIKit attaches its labels.
            host.setOverrideTraitCollection(nil, forChild: controller)
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
                                            forChild: controller)
            host.view.frame = window.bounds
            controller.view.frame = host.view.bounds
            host.view.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first)
            XCTAssertGreaterThan(scroll.bounds.height, 100)
            let author = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UILabel }
                .first { $0.accessibilityIdentifier == "fullPlayer.bookAuthor" })
            XCTAssertEqual(author.text, displayedBook.author)
            XCTAssertFalse(author.isHidden)
            XCTAssertGreaterThan(author.font.pointSize, 30, "Font must scale in \(size): \(author.traitCollection.preferredContentSizeCategory)")
            XCTAssertGreaterThanOrEqual(author.bounds.height,
                author.sizeThatFits(CGSize(width: author.bounds.width, height: .greatestFiniteMagnitude)).height - 1)
            for identifier in ["fullPlayer.bookTitle", "fullPlayer.progress", "fullPlayer.playbackRateButton"] {
                let control = try XCTUnwrap(descendants(scroll).first { $0.accessibilityIdentifier == identifier },
                                            "Metadata and controls must share the scroll surface")
                scroll.scrollRectToVisible(control.convert(control.bounds, to: scroll), animated: false)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: scroll)),
                              "Player control must be reachable: \(identifier), \(size)")
            }
        }
    }

    func testExpandedPlayerMetadataFollowsAccessibilityTextSize() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
            library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        for identifier in ["fullPlayer.bookTitle", "fullPlayer.bookAuthor"] {
            let label = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UILabel }
                .first { $0.accessibilityIdentifier == identifier })
            XCTAssertTrue(label.adjustsFontForContentSizeCategory)
            XCTAssertEqual(label.numberOfLines, 0)
        }
    }

    func testJobPlayerScrollsOnSEAndNamesIconControlsForVoiceOver() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
        {"jobId":"responsive-player","state":"completed","bookTitle":"A long audiobook title for a compact phone","chapterProgress":[]}
        """.utf8))
        player.play(snapshot: snapshot, startingAt: 0, restoreAutoplay: false)
        let controller = PlayerScreenController(snapshot: snapshot, backendBaseURL: nil,
                                                 player: player, playbackClock: PlaybackClock())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        let views = descendants(controller.view)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        let names = Set([L10n.string("player.previousChapter"), L10n.string("player.nextChapter"), L10n.string("player.play")])
        let controls = views.compactMap { $0 as? UIButton }.filter { names.contains($0.accessibilityLabel ?? "") }
        XCTAssertEqual(controls.count, 3)
        for control in controls {
            XCTAssertFalse((control.accessibilityLabel ?? "").isEmpty, "Icon transport must have a spoken name")
            XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
            scroll.scrollRectToVisible(control.convert(control.bounds, to: scroll), animated: false)
            XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: scroll)))
        }
        let title = try XCTUnwrap(views.compactMap { $0 as? UILabel }.first { $0.text == snapshot.bookTitle })
        XCTAssertTrue(title.adjustsFontForContentSizeCategory)
        XCTAssertEqual(title.numberOfLines, 0)
    }

    func testBookActionsFitAndRemainReachableOnCompactAndLargePhones() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 428, height: 926), CGSize(width: 568, height: 320)] {
            try verifyBookDetail(size: size, category: .large)
        }
    }

    func testBookActionsRemainReachableAtAccessibilityTextSize() throws {
        try verifyBookDetail(size: CGSize(width: 320, height: 568), category: .accessibilityExtraExtraExtraLarge)
    }

    private func verifyBookDetail(size: CGSize, category: UIContentSizeCategory) throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = BookDetailScreenController(book: book, library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: PlayerPresentation(defaults: defaults))
        let host = UIViewController()
        host.addChild(controller)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        controller.view.frame = host.view.bounds
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let views = descendants(controller.view)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first)
        let buttons = views.compactMap { $0 as? UIButton }
        for text in [book.resolvedTitle, book.author ?? ""] {
            let label = try XCTUnwrap(views.compactMap { $0 as? UILabel }.first { $0.text == text })
            XCTAssertTrue(label.adjustsFontForContentSizeCategory, "Book metadata must follow Dynamic Type")
            XCTAssertEqual(label.numberOfLines, 0, "Book metadata must wrap")
        }
        for key in ["bookDetail.read", "bookDetail.listenStart", "bookDetail.download", "conversion.log"] {
            let title = L10n.string(key)
            let button = try XCTUnwrap(buttons.first { $0.title(for: .normal) == title || $0.configuration?.title == title })
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44, "\(title), \(size), \(category)")
            XCTAssertLessThanOrEqual(button.bounds.width, scroll.bounds.width)
            if let label = button.titleLabel {
                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                XCTAssertLessThanOrEqual(required.height, label.bounds.height + 1, "Action title must not clip: \(title)")
            }
            let frame = button.convert(button.bounds, to: scroll)
            scroll.scrollRectToVisible(frame, animated: false)
            scroll.layoutIfNeeded()
            XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(button.convert(button.bounds, to: scroll)),
                          "Action must be reachable by scrolling: \(title)")
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #else
    func testLibraryToolbarImportIsPresentInAccessibleChildren() throws {
        let controller = MacLibraryViewController(library: LibraryStore(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        controller.loadViewIfNeeded()
        let add = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "library.add" })
        XCTAssertEqual(add.accessibilityLabel(), L10n.string("library.addBook"))
        XCTAssertTrue((controller.view.accessibilityChildren() ?? []).contains { ($0 as? NSView) === add })
    }

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
                                  ("layout", "reader.layout"), ("margin", "reader.margins"),
                                  ("kerning", "reader.kerning"), ("columns", "reader.columns")] {
            let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "readerSettings.\(identifier)" })
            XCTAssertEqual(popup.accessibilityLabel(), L10n.string(key))
        }
        for key in ["readerSettings.decreaseFontSize", "readerSettings.increaseFontSize"] {
            XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == L10n.string(key) })
        }
    }

    func testLiveMacWindowSettingsAndLOTRPageRoundTrip() async throws {
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
        NSApp.mainMenu = EpubToMp3App.makeMainMenu(target: application)
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
            let label: String? = button.accessibilityLabel()
            return (identifier?.hasPrefix("library.book.open.") ?? false)
                && ((label?.localizedCaseInsensitiveContains("Lord of the Rings") ?? false)
                    || (label?.localizedCaseInsensitiveContains("Senhor dos Anéis") ?? false))
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

    private func captureLiveWindow(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        window.backgroundColor.setFill()
        view.bounds.fill()
        bitmap.draw(in: view.bounds)
        image.unlockFocus()
        let flattened = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(flattened.representation(using: .png, properties: [:]))
        try png.write(to: url)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func childControllers(_ controller: NSViewController) -> [NSViewController] {
        controller.children + controller.children.flatMap(childControllers)
    }

    func testExpandedPlayerFitsShortWindowAndNamesTransportControls() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = MacFullPlayerViewController(player: player, library: LibraryStore(defaults: defaults),
            presentation: PlayerPresentation(defaults: defaults), onStartPlayback: {})
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("common.close"))
        let views = descendants(controller.view)
        for (identifier, key) in [("fullPlayer.previousChapter", "player.previousChapter"),
                                  ("fullPlayer.nextChapter", "player.nextChapter"),
                                  ("fullPlayer.playPause", "player.play")] {
            let control = try XCTUnwrap(views.compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier })
            XCTAssertEqual(control.accessibilityLabel(), L10n.string(key))
            XCTAssertEqual(control.toolTip, L10n.string(key))
        }
        let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.accessibilityLabel(), L10n.string("player.playbackPosition"))
    }

    func testSettingsControlsFitResizedWindowAndLastActionCanScrollIntoView() throws {
        let controller = MacSettingsViewController(settings: AppSettings(defaults: defaults),
                                                   library: LibraryStore(defaults: defaults))
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("settings.clearAllDownloads"))
    }

    func testBookDetailActionsRemainReachableInShortWindow() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = MacBookDetailViewController(book: book, library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: PlayerPresentation(defaults: defaults), onRead: { _ in }, onShowJobs: {})
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("conversion.log"))
    }

    private func verifyMacScrolling(_ controller: NSViewController, sizes: [NSSize], lastTitle: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: sizes[0]),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        for size in sizes {
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            let views = descendants(controller.view)
            let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            for button in buttons {
                let frame = button.convert(button.bounds, to: document)
                XCTAssertGreaterThan(button.bounds.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.width + 1,
                                         "Control must fit resized window: \(button.title)")
            }
            let last = try XCTUnwrap(buttons.first { $0.title == lastTitle })
            document.scrollToVisible(last.convert(last.bounds, to: document))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertTrue(scroll.contentView.bounds.insetBy(dx: -1, dy: -1)
                .contains(last.convert(last.bounds, to: document)), "Last action must be reachable by scrolling")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #endif
}
#endif
