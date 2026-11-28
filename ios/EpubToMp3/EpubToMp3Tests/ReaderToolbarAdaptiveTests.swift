import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The "recent tool + more" pair exists for phones only. Wider readers show every tool that fits.
@MainActor
final class ReaderToolbarAdaptiveTests: XCTestCase {
    private let available = ReaderTool.allCases.filter { $0.isAvailable(hasFootnotes: false) }

#if os(macOS)
    func testWideReaderShowsEveryToolAndResizingMovesOnlyTheRestToMore() async throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: harness.defaults), settings: harness.settings,
            player: harness.player, bookmarkStore: harness.bookmarks, onClose: {})
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 600))
            window.layoutIfNeeded()
        }
        func buttons() -> [NSButton] { descendants(controller.view).compactMap { $0 as? NSButton } }
        func inline() -> [String] {
            buttons().filter { button in !button.isHiddenOrHasHiddenAncestor
                    && available.contains { $0.accessibilityIdentifier == button.accessibilityIdentifier() } }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                .map { $0.accessibilityIdentifier() }
        }
        func overflow() -> [String] {
            guard let more = buttons().first(where: { $0.accessibilityIdentifier() == "reader.more" }),
                  !more.isHidden else { return [] }
            return more.menu?.items.compactMap { $0.accessibilityIdentifier() } ?? []
        }
        let expected = available.map(\.accessibilityIdentifier)

        resize(1100)
        XCTAssertEqual(inline(), expected, "A wide reader shows every tool in the toolbar, in order")
        XCTAssertEqual(overflow(), [], "Nothing is left for the more menu when everything fits")

        resize(420)
        XCTAssertFalse(overflow().isEmpty, "A narrow window moves the tools that do not fit to the more menu")
        XCTAssertFalse(inline().isEmpty, "Tools that still fit stay in the toolbar")
        XCTAssertEqual(inline() + overflow(), expected, "Each tool appears exactly once, in the same order")
        for button in buttons() where !button.isHiddenOrHasHiddenAncestor {
            XCTAssertLessThanOrEqual(button.convert(button.bounds, to: controller.view).maxX,
                                     controller.view.bounds.maxX + 0.5, "No toolbar button may be clipped")
        }

        resize(1100)
        XCTAssertEqual(inline(), expected, "Widening the window brings the tools back")
    }
#else
    func testRegularWidthReaderShowsEveryToolAndCompactKeepsTheRecentToolPair() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let reader = BookOpenScreenController(book: harness.book,
            library: LibraryStore(defaults: harness.defaults), settings: harness.settings,
            bookmarkStore: harness.bookmarks, player: harness.player, sessionDefaults: harness.defaults)
        let parent = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = parent
        window.isHidden = false
        defer { window.isHidden = true }
        parent.addChild(reader)
        parent.view.addSubview(reader.view)
        reader.didMove(toParent: parent)
        let item = UINavigationItem()
        reader.installNavigationBarButtonItems(in: item)

        func resize(_ width: CGFloat, _ sizeClass: UIUserInterfaceSizeClass) {
            parent.setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: sizeClass), forChild: reader)
            reader.view.frame = CGRect(x: 0, y: 0, width: width, height: 768)
            reader.view.setNeedsLayout()
            reader.view.layoutIfNeeded()
        }
        /// UIKit lists right bar items from the trailing edge, so reading order is reversed.
        func identifiers() -> [String] { (item.rightBarButtonItems ?? []).reversed().compactMap(\.accessibilityIdentifier) }
        func overflow() -> [String] {
            let more = item.rightBarButtonItems?.first { $0.accessibilityIdentifier == "reader.more" }
            return more?.menu?.children.compactMap { ($0 as? UIAction)?.identifier.rawValue } ?? []
        }
        let expected = available.map(\.accessibilityIdentifier)

        resize(1024, .regular)
        XCTAssertEqual(identifiers(), expected, "Regular width shows every tool, in order, with no more menu")

        resize(500, .regular)
        XCTAssertFalse(overflow().isEmpty)
        XCTAssertEqual(identifiers().filter { $0 != "reader.more" } + overflow(), expected,
                       "Only the tools that do not fit move to the more menu")

        resize(390, .compact)
        XCTAssertEqual(identifiers(), ["reader.settings.toggle", "reader.more"], "Phones keep the recent tool and more")
        XCTAssertEqual(overflow(), expected, "The phone menu keeps every tool")
    }
#endif
}
