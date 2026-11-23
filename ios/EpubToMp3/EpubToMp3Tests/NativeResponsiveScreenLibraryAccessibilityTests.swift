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
