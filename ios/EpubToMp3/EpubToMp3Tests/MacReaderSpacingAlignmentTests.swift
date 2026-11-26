#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The iPhone appearance panel offers alignment and line spacing, so the Mac panel must too.
@MainActor
final class MacReaderSpacingAlignmentTests: XCTestCase {
    func testAppearancePanelChangesAlignmentAndLineSpacing() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let popover = NSPopover()
        let presentation = MacReaderSettingsPresentation(settings: harness.settings, popover: popover)
        presentation.prepareForTesting()
        let scroll = try XCTUnwrap(popover.contentViewController?.view as? NSScrollView)
        let views = descendants(try XCTUnwrap(scroll.documentView))

        let alignment = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "readerSettings.alignment" }, "missing alignment control")
        XCTAssertEqual(alignment.itemTitles, ReaderTextAlignment.allCases.map(\.displayName))
        let target = try XCTUnwrap(ReaderTextAlignment.allCases.first { $0 != harness.settings.readerTextAlignment })
        alignment.selectItem(at: try XCTUnwrap(ReaderTextAlignment.allCases.firstIndex(of: target)))
        XCTAssertTrue(alignment.sendAction(alignment.action, to: alignment.target))
        XCTAssertEqual(harness.settings.readerTextAlignment, target)

        let spacing = try XCTUnwrap(views.compactMap { $0 as? NSSlider }
            .first { $0.accessibilityIdentifier() == "readerSettings.lineSpacing" }, "missing line spacing control")
        spacing.doubleValue = spacing.maxValue
        XCTAssertTrue(spacing.sendAction(spacing.action, to: spacing.target))
        XCTAssertEqual(harness.settings.readerLineSpacing, PointPresetScale.lineSpacing.last)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
#endif
