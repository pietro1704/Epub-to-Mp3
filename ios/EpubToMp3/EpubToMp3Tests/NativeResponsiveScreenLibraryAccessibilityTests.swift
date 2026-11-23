#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@testable import EpubToMp3

extension NativeResponsiveScreenTests {

    func testLibraryReopensWithPlayedBookFirstUnlessAnotherSortWasChosen() throws {
        let sortKey = "library.sortMode.v1"
        let previous = UserDefaults.standard.object(forKey: sortKey)
        defer { restore(previous, key: sortKey, defaults: .standard) }
        UserDefaults.standard.removeObject(forKey: sortKey)

        let opened = BookEntity(id: "opened", title: "A", bookmark: Data([1]),
            displayFilename: "a.epub", addedAt: Date(), lastOpenedAt: Date())
        var played = BookEntity(id: "played", title: "Z", bookmark: Data([2]),
            displayFilename: "z.epub", addedAt: .distantPast)
        played.lastPlayedAt = Date(timeIntervalSince1970: 42)
        defaults.set(try JSONEncoder().encode([opened, played]), forKey: "library.books.v1")

        func firstBookTile() throws -> String? {
            let library = LibraryStore(defaults: defaults)
            let bookmarks = BookmarkStore(defaults: defaults, storageKey: "bookmarks")
            XCTAssertEqual(library.books.count, 2)
#if os(iOS)
            let controller = LibraryScreenController(library: library, settings: AppSettings(defaults: defaults),
                player: AudioPlayer(), playerPresentation: PlayerPresentation(defaults: defaults), bookmarkStore: bookmarks)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            window.layoutIfNeeded()
            let grid = try XCTUnwrap(controller.children.compactMap { $0 as? LibraryGridController }.first)
            grid.collectionView.layoutIfNeeded()
            let tile = try XCTUnwrap(grid.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
            return tile.accessibilityLabel
#else
            let controller = MacLibraryViewController(library: library, bookmarkStore: bookmarks,
                onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
            controller.loadViewIfNeeded()
            let grid = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSCollectionView }.first)
            let tile = controller.collectionView(grid, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
            return tile.view.accessibilityLabel()
#endif
        }

        XCTAssertEqual(try firstBookTile(), played.resolvedTitle)
        LibraryGridModel.SortMode.title.save()
        XCTAssertEqual(try firstBookTile(), opened.resolvedTitle)
    }
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
#else
    func testLibraryToolbarImportIsPresentInAccessibleChildren() throws {
        let controller = MacLibraryViewController(library: LibraryStore(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        controller.loadViewIfNeeded()
        let add = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "library.add" })
        XCTAssertEqual(add.accessibilityLabel(), L10n.string("library.addBook"))
        // AppKit exposes a flattened control through its cell, so the import
        // button is reachable either as the view or as its NSButtonCell.
        let accessible = controller.view.accessibilityChildren() ?? []
        XCTAssertTrue(accessible.contains { ($0 as AnyObject) === add || ($0 as AnyObject) === add.cell })
    }
#endif

#if os(iOS)
#else
    func testMacSecondaryVoiceMenuValidationKeepsPrimaryDisabled() throws {
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(nil)
        // Since #1145 the narration popups live in the pushed Voice models
        // detail; MacVoiceModelSettingsNavigationTests covers the push itself.
        let controller = MacSettingsViewController(settings: settings, library: LibraryStore(defaults: defaults),
                                                   voiceModelsOnly: true)
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
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Piper")).isEnabled,
                       "AppKit menu validation must preserve the primary-voice exclusion.")
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Edge")).isEnabled)

        secondary.selectItem(withTitle: "Piper")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertNil(settings.ttsPreferences.secondary, "A stale or programmatic action must not persist a duplicate voice.")
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "edge")

        let captured = NarrationConversionOptions.current(for: settings.ttsPreferences)
        secondary.selectItem(withTitle: "Piper")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.secondary?.engine, "edge")
        XCTAssertEqual(secondary.titleOfSelectedItem, "Edge")
        // The captured job keeps its own (catalog-captured) preferences.
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences, captured.ttsPreferences)
        secondary.selectItem(withTitle: L10n.string("settings.noSecondary"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertNil(AppSettings(defaults: defaults).ttsPreferences.secondary)
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "edge")
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))

        primary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        menu.update()
        XCTAssertNil(settings.ttsPreferences.secondary, "The new primary voice cannot remain the secondary voice.")
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Edge")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Piper")).isEnabled,
                       "Changing the primary cannot make an uninstalled model selectable.")
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))
    }
#endif

#if os(iOS)
#else
    func testMacConvertScreenTtsOverrideStartsStrictAndKeepsInheritedPreferences() throws {
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(.edgeDefault)
        let original = settings.ttsPreferences
        var conversions = 0
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, _, _, _, _, _, _ in
            conversions += 1
            XCTFail("Changing manual voice controls must not submit synthesis.")
            throw CancellationError()
        }))
        let controller = MacConvertScreenController(settings: settings, library: LibraryStore(defaults: defaults),
                                                   viewModel: model)
        _ = controller.view
        let choice = controller.form.engine
        let secondary = controller.form.secondary
        let action = try XCTUnwrap(choice.action)
        XCTAssertEqual(choice.titleOfSelectedItem, L10n.string("convert.usePreferences"))
        XCTAssertEqual(secondary.state, .on)
        XCTAssertFalse(secondary.isEnabled)
        choice.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
        XCTAssertEqual(choice.titleOfSelectedItem, "Edge")
        XCTAssertEqual(secondary.state, .off, "An override must begin strict even when defaults have a secondary.")
        XCTAssertFalse(secondary.isEnabled, "The saved Edge secondary duplicates this manual primary.")
        choice.selectItem(withTitle: "Piper")
        XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
        XCTAssertTrue(secondary.isEnabled)
        secondary.performClick(nil)
        XCTAssertEqual(secondary.state, .on)
        choice.selectItem(withTitle: L10n.string("convert.usePreferences"))
        XCTAssertTrue(NSApp.sendAction(action, to: choice.target, from: choice))
        XCTAssertEqual(secondary.state, .on)
        XCTAssertFalse(secondary.isEnabled)
        XCTAssertEqual(conversions, 0)
        XCTAssertEqual(settings.ttsPreferences, original)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences, original)
    }
#endif

#if os(iOS)
#else
    func testMacConvertScreenActionsRemainReachableInShortWindow() throws {
        let controller = MacConvertScreenController(settings: AppSettings(defaults: defaults),
                                                   library: LibraryStore(defaults: defaults))
        _ = controller.view
        try verifyMacScrolling(controller, sizes: [NSSize(width: 520, height: 300), NSSize(width: 900, height: 700)],
                               lastTitle: controller.form.submit.title)
    }
#endif
}
#endif
