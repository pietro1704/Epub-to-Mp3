#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MAC-SETTINGS-TABS-LIKE-LINUX: the macOS Settings screen follows the Linux
/// (Flutter) organization — Models first, then Reader with a Reading
/// preferences page, Playback, Storage, Advanced and About — while the rows
/// keep the iPhone content.
@MainActor
final class MacSettingsLinuxLayoutTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "MacSettingsLinuxLayout.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    func testSectionsFollowTheLinuxOrderWithReadingPreferencesOnTheirOwnPage() throws {
        let settings = AppSettings(defaults: defaults)
        let (controller, window) = host(settings)
        defer { window.close() }

        let titles = ["models.title", "settings.reader", "settings.playback", "settings.storage",
                      "settings.advanced", "settings.about"].map { L10n.string($0) }
        let tops = try titles.map { title -> CGFloat in
            let label = try XCTUnwrap(labels(in: controller.view).first { $0.stringValue == title },
                                      "Missing Settings section \(title)")
            return label.convert(label.bounds, to: nil).maxY
        }
        XCTAssertEqual(tops, tops.sorted(by: >), "Sections must read top to bottom as \(titles)")

        XCTAssertNil(control(in: controller.view, identifier: "settings.font"),
                     "Reader appearance lives on the Reading preferences page, as on Linux")
        let disclosure = try XCTUnwrap(control(in: controller.view,
                                               identifier: "settings.readingPreferences.disclosure") as? NSButton)
        attach(window, name: "mac-settings-linux-layout")
        disclosure.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(labels(in: controller.view).contains { $0.stringValue == L10n.string("settings.readingPreferences") })
        for identifier in ["settings.fontSize", "settings.font", "settings.theme", "settings.layout"] {
            let view = try XCTUnwrap(control(in: controller.view, identifier: identifier), identifier)
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, identifier)
        }
        attach(window, name: "mac-settings-reading-preferences")
        let back = try XCTUnwrap(control(in: controller.view, identifier: "settings.voiceModels.back") as? NSButton)
        back.performClick(nil)
        XCTAssertFalse(disclosure.isHiddenOrHasHiddenAncestor)
    }

    func testReaderAndPlaybackRowsChangeTheSharedSettings() throws {
        let settings = AppSettings(defaults: defaults)
        settings.readerAutoScroll = true
        settings.readerAudioTrackingEnabled = true
        settings.playbackForwardSeconds = 15
        settings.playbackBackwardSeconds = 15
        settings.remoteButtonMode = .chapter
        let (controller, window) = host(settings)
        defer { window.close() }

        let autoScroll = try XCTUnwrap(control(in: controller.view, identifier: "settings.reader.autoScroll") as? NSSwitch)
        XCTAssertEqual(autoScroll.state, .on)
        let trailing = autoScroll.convert(autoScroll.bounds, to: controller.view).maxX
        XCTAssertGreaterThan(trailing, controller.view.bounds.width * 0.75,
                             "Row controls sit at the trailing edge, as on Linux")
        autoScroll.performClick(nil)
        XCTAssertFalse(settings.readerAutoScroll)
        let tracking = try XCTUnwrap(control(in: controller.view, identifier: "settings.reader.audioTracking") as? NSSwitch)
        tracking.performClick(nil)
        XCTAssertFalse(settings.readerAudioTrackingEnabled)

        for (identifier, forward) in [("settings.skipForward", true), ("settings.skipBackward", false)] {
            let popup = try XCTUnwrap(control(in: controller.view, identifier: identifier) as? NSPopUpButton)
            XCTAssertEqual(popup.itemTitles, [15, 30, 45, 60].map { L10n.string("settings.seconds", $0) })
            XCTAssertEqual(popup.titleOfSelectedItem, L10n.string("settings.seconds", 15))
            popup.selectItem(at: 1)
            _ = popup.target?.perform(popup.action, with: popup)
            XCTAssertEqual(forward ? settings.playbackForwardSeconds : settings.playbackBackwardSeconds, 30)
        }

        let remote = try XCTUnwrap(control(in: controller.view, identifier: "settings.remoteButtons") as? NSSegmentedControl)
        XCTAssertEqual((0..<remote.segmentCount).map { remote.label(forSegment: $0) },
                       RemoteButtonMode.allCases.map(\.title))
        XCTAssertEqual(remote.selectedSegment, 0)
        remote.selectedSegment = 1
        _ = remote.target?.perform(remote.action, with: remote)
        XCTAssertEqual(settings.remoteButtonMode, .skip)

        let platform = try XCTUnwrap(control(in: controller.view, identifier: "settings.platform") as? NSTextField)
        XCTAssertEqual(platform.stringValue, "macOS")
    }

    /// PARITY-MAC-SETTINGS-2: as on Linux, from 960 points Models and the preferences
    /// scroll in two side-by-side columns; narrower, they stay in one.
    func testWideSettingsShowModelsAndPreferencesInTwoColumns() throws {
        let (controller, window) = host(AppSettings(defaults: defaults))
        defer { window.close() }

        for (width, columns) in [(CGFloat(1200), true), (900, false), (1100, true)] {
            window.setContentSize(NSSize(width: width, height: 700))
            controller.view.layoutSubtreeIfNeeded()
            let models = try XCTUnwrap(control(in: controller.view, identifier: "settings.speechModels.disclosure"))
            let reader = try XCTUnwrap(control(in: controller.view, identifier: "settings.reader.autoScroll"))
            let modelsScroll = try XCTUnwrap(models.enclosingScrollView)
            let readerScroll = try XCTUnwrap(reader.enclosingScrollView)
            XCTAssertEqual(modelsScroll !== readerScroll, columns, "two columns at \(width)")
            if columns {
                let left = modelsScroll.convert(modelsScroll.bounds, to: controller.view)
                let right = readerScroll.convert(readerScroll.bounds, to: controller.view)
                XCTAssertLessThanOrEqual(left.maxX, right.minX, "Models on the left at \(width)")
                XCTAssertEqual(left.width, right.width, accuracy: 2, "equal columns at \(width)")
                XCTAssertEqual(right.maxX, controller.view.bounds.maxX, accuracy: 2)
            }
            XCTAssertEqual(window.contentView?.bounds.width ?? 0, width, accuracy: 1, "layout must not resize the window")
        }
    }

    /// PARITY-MAC-SETTINGS-4: the Reading preferences page carries the same preferences as on Linux.
    func testReadingPreferencesPageEditsTheRemainingPreferences() throws {
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        settings.readerFontFamily = .serif
        settings.readerOverrideFontSize = true
        let (controller, window) = host(settings)
        defer { window.close() }
        let disclosure = try XCTUnwrap(control(in: controller.view,
                                               identifier: "settings.readingPreferences.disclosure") as? NSButton)
        disclosure.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        func find(_ identifier: String) throws -> NSView {
            try XCTUnwrap(control(in: controller.view, identifier: identifier), "missing \(identifier)")
        }
        func choose(_ identifier: String, _ index: Int) throws {
            let popup = try XCTUnwrap(try find(identifier) as? NSPopUpButton)
            popup.selectItem(at: index)
            popup.sendAction(popup.action, to: popup.target)
        }
        _ = try find("settings.lineSpacing")
        _ = try find("settings.margin")
        try choose("settings.alignment", try XCTUnwrap(ReaderTextAlignment.allCases.firstIndex(of: .left)))
        XCTAssertEqual(settings.readerTextAlignment, .left)
        try choose("settings.pageTurnStyle", 1)
        XCTAssertEqual(settings.pageTurnStyle, PageTurnStyle.none)
        let numbers = try XCTUnwrap(try find("settings.pageNumbers") as? NSButton)
        let shown = settings.readerShowPageNumbers
        numbers.performClick(nil)
        XCTAssertEqual(settings.readerShowPageNumbers, !shown)
        attach(window, name: "mac-reading-preferences")
        try XCTUnwrap(try find("settings.originalTypography") as? NSButton).performClick(nil)
        XCTAssertFalse(settings.readerOverrideFontFamily)
        XCTAssertFalse(settings.readerOverrideFontSize)
        try choose("settings.layout", try XCTUnwrap(ReaderLayout.allCases.firstIndex(of: .scrolling)))
        // `control` only returns visible views.
        XCTAssertNil(control(in: controller.view, identifier: "settings.pageTurnStyle"), "scrolling has no page turns")
        XCTAssertNil(control(in: controller.view, identifier: "settings.pageNumbers"))
    }

    private func host(_ settings: AppSettings) -> (MacSettingsViewController, NSWindow) {
        let controller = MacSettingsViewController(settings: settings, library: LibraryStore(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 1400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 1400))
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func labels(in view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func control(in view: NSView, identifier: String) -> NSView? {
        descendants(view).first { $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func attach(_ window: NSWindow, name: String) {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return XCTFail("Cannot capture the Settings window")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
