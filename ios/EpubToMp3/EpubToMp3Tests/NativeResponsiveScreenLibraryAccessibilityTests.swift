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
#endif

#if os(iOS)
    func testBookActionsFitAndRemainReachableOnCompactAndLargePhones() throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 428, height: 926), CGSize(width: 568, height: 320)] {
            try verifyBookDetail(size: size, category: .large)
        }
    }
#endif

#if os(iOS)
    func testBookActionsRemainReachableAtAccessibilityTextSize() throws {
        try verifyBookDetail(size: CGSize(width: 320, height: 568), category: .accessibilityExtraExtraExtraLarge)
    }
#endif

#if os(iOS)
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
#endif

#if os(iOS)
#else
    func testMacSecondaryVoiceMenuValidationKeepsPrimaryDisabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        settings.secondaryAudioEngine = nil
        let controller = MacSettingsViewController(settings: settings, library: LibraryStore(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        let controls = descendants(controller.view).compactMap { $0 as? NSPopUpButton }
        let primary = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "settings.tts.primary" })
        let secondary = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "settings.tts.secondary" })
        let menu = try XCTUnwrap(secondary.menu)
        menu.update()
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: AudioEnginePreference.piper.displayName)).isEnabled,
                       "AppKit menu validation must preserve the primary-voice exclusion.")
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Edge")).isEnabled)

        secondary.selectItem(withTitle: AudioEnginePreference.piper.displayName)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertNil(settings.secondaryAudioEngine, "A stale or programmatic action must not persist a duplicate voice.")
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(settings.secondaryAudioEngine, .edge)

        let captured = settings.conversionOptions
        secondary.selectItem(withTitle: AudioEnginePreference.piper.displayName)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(AppSettings(defaults: defaults).secondaryAudioEngine, .edge)
        XCTAssertEqual(secondary.titleOfSelectedItem, "Edge")
        XCTAssertEqual(settings.ttsPreferences, captured.ttsPreferences)
        secondary.selectItem(withTitle: L10n.string("settings.noSecondary"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertNil(AppSettings(defaults: defaults).secondaryAudioEngine)
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "edge")
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))

        primary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        menu.update()
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Edge")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: AudioEnginePreference.piper.displayName)).isEnabled,
                       "Changing the primary cannot make an uninstalled model selectable.")
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
    }
#endif

#if os(iOS)
#else
    func testMacManualTtsDialogSupportsInheritanceAndStrictOverrideBeforeCancel() throws {
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        settings.secondaryAudioEngine = .edge
        let original = settings.ttsPreferences
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var conversions = 0
        let controller = MacBookDetailViewController(book: book, library: LibraryStore(defaults: defaults),
            settings: settings, player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            onRead: { _ in }, onShowJobs: {}, conversionExecutor: { _, _, _, _, _, _, _ in
                conversions += 1
                XCTFail("Cancelling the actual dialog must not submit synthesis.")
                throw CancellationError()
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentViewController = nil; window.close() }
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "bookDetail.convert" })
        for publicEntry in [false, true] {
            var inspected = false
            let deadline = Date().addingTimeInterval(3)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow else {
                        if Date() > deadline { timer.invalidate(); NSApp.abortModal(); XCTFail("The native conversion dialog did not open.") }
                        return
                    }
                    defer { timer.invalidate(); NSApp.abortModal(); modal.orderOut(nil) }
                    guard let surface = modal.contentView,
                          let choice = self.descendants(surface).compactMap({ $0 as? NSPopUpButton })
                            .first(where: { $0.accessibilityIdentifier() == "convert.tts.primary" }),
                          let secondary = self.descendants(surface).compactMap({ $0 as? NSButton })
                            .first(where: { $0.accessibilityIdentifier() == "convert.tts.useSecondary" }),
                          let action = choice.action else {
                        XCTFail("The actual modal must expose primary and secondary controls.")
                        return
                    }
                    inspected = true
                    XCTAssertEqual(choice.titleOfSelectedItem, L10n.string("convert.usePreferences"))
                    XCTAssertEqual(secondary.state, .on)
                    XCTAssertFalse(secondary.isEnabled)
                    choice.selectItem(withTitle: "Edge")
                    XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
                    XCTAssertEqual(choice.titleOfSelectedItem, "Edge")
                    XCTAssertEqual(secondary.state, .off, "An override must begin strict even when defaults have a secondary.")
                    XCTAssertFalse(secondary.isEnabled, "The saved Edge secondary duplicates this manual primary.")
                    choice.selectItem(withTitle: AudioEnginePreference.piper.displayName)
                    XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
                    secondary.performClick(nil)
                    XCTAssertEqual(secondary.state, .on)
                    choice.selectItem(withTitle: L10n.string("convert.usePreferences"))
                    XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
                    XCTAssertEqual(secondary.state, .on)
                    XCTAssertFalse(secondary.isEnabled)
                    XCTAssertEqual(settings.ttsPreferences, original)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            if publicEntry { controller.convertWholeBook() } else { button.performClick(nil) }
            XCTAssertTrue(inspected, "Both the detail button and library conversion entry must present the modal.")
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertEqual(conversions, 0)
            XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences, original)
        }
    }
#endif

#if os(iOS)
#else
    func testBookDetailActionsRemainReachableInShortWindow() throws {
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = MacBookDetailViewController(book: book, library: LibraryStore(defaults: defaults),
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: PlayerPresentation(defaults: defaults), onRead: { _ in }, onShowJobs: {})
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: L10n.string("conversion.log"))
    }
#endif
}
#endif
