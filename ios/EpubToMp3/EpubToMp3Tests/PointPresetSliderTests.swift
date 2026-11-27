import XCTest
@testable import EpubToMp3

final class PointPresetScaleTests: XCTestCase {
    func testAnExistingValueRemainsReachableWithoutChangingStoredPreferences() {
        XCTAssertEqual(PointPresetScale.preserving(23, in: PointPresetScale.font), [14, 17, 20, 23, 24, 28, 32, 36, 42, 48])
        XCTAssertEqual(PointPresetScale.preserving(20, in: PointPresetScale.font), PointPresetScale.font)
    }

    func testIrregularFontScaleKeepsTheExistingNearestChoices() {
        XCTAssertEqual(PointPresetScale.font, [14, 17, 20, 24, 28, 32, 36, 42, 48])
        XCTAssertEqual(PointPresetScale.nearestIndex(to: 23.5, in: PointPresetScale.font), 3)
        XCTAssertEqual(PointPresetScale.nearestIndex(to: -5, in: PointPresetScale.font), 0)
        XCTAssertEqual(PointPresetScale.nearestIndex(to: 100, in: PointPresetScale.font), 8)
    }

    /// READER-FONT-MAX-LARGER: low-vision readers need sizes above 28 pt.
    @MainActor
    func testLargerReaderSizesCanBeSelectedAndSurviveARelaunch() throws {
        let suite = "reader-large-font-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for size in [32.0, 36, 42, 48] {
            settings.readerFontSize = PointPresetScale.nearestIndex(to: size, in: PointPresetScale.font)
            XCTAssertEqual(Double(settings.readerPointSize), size)
            XCTAssertEqual(Double(AppSettings(defaults: defaults).readerPointSize), size)
        }
        // Stored steps keep the size they had before the scale grew.
        settings.readerFontSize = 4
        XCTAssertEqual(settings.readerPointSize, 28)
        settings.readerFontSize = 100
        XCTAssertEqual(settings.readerPointSize, 48)
    }
}

#if os(iOS)
import UIKit

@MainActor
final class ReaderLargestFontPaginationTests: XCTestCase {
    func testLargestAppSizeKeepsTheSystemTextSizeAndStartsEveryPageOnAWholeLine() throws {
        let text = String(repeating: "Large print keeps every line whole across pages. ", count: 60)
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter(text)])
        harness.installTeardown(in: self)
        harness.settings.readerFontSize = ReaderFontScale.maximumStep
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
            harness.showChapter(0)
            harness.controller.view.layoutIfNeeded()
            harness.text.layoutCommittedViewport()
        }
        let font = try XCTUnwrap(harness.displayed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, 48, "The system Text Size still multiplies the app size.")

        let offsets = harness.text.paginatedPageOffsets
        XCTAssertGreaterThan(offsets.count, 1)
        XCTAssertEqual(offsets, offsets.sorted())
        let textView = harness.composition.textView
        var lineTops: [CGFloat] = [0]
        textView.layoutManager.enumerateLineFragments(
            forGlyphRange: textView.layoutManager.glyphRange(for: textView.textContainer)
        ) { rect, _, _, _, _ in lineTops.append(rect.minY + textView.textContainerInset.top) }
        for offset in offsets {
            XCTAssertTrue(lineTops.contains { abs($0 - offset) < 1 }, "Page at \(offset) splits a line.")
        }
    }
}

@MainActor
final class PointPresetSliderTests: XCTestCase {
    func testNativeSliderAndAccessibilityUseTheSamePresetValues() {
        let slider = PointPresetSlider()
        slider.configure(presets: PointPresetScale.font, current: 20)
        var observed: [Double] = []
        slider.onPointChange = { observed.append($0) }
        slider.value = 2.7
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(slider.value, 3)
        XCTAssertEqual(slider.selectedPointValue, 24)
        XCTAssertEqual(observed, [24])
        slider.accessibilityDecrement()
        XCTAssertEqual(slider.selectedPointValue, 20)
        slider.accessibilityIncrement()
        XCTAssertEqual(slider.selectedPointValue, 24)
        XCTAssertEqual(slider.accessibilityValue, PointPresetScale.label(24))
    }

    func testSettingsRowsUpdateWithoutReplacingTheSliderOrPresentingAnAlert() throws {
        let suite = "PresetSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let table = UITableView(frame: .zero, style: .insetGrouped)
        let rows = ReaderSettingsRows(tableView: table, settings: settings)
        let cell = try XCTUnwrap(rows.cell(for: IndexPath(row: 4, section: 3)) as? PointPresetCell)
        let slider = cell.slider
        XCTAssertEqual(slider.presets, PointPresetScale.lineSpacing)
        slider.value = 3.1
        slider.sendActions(for: .valueChanged)
        XCTAssertTrue(cell.slider === slider)
        XCTAssertEqual(settings.readerLineSpacing, 6)
        XCTAssertEqual(AppSettings(defaults: defaults).readerLineSpacing, 6)
        XCTAssertNil(cell.inputViewController)
    }
}
#elseif os(macOS)
import AppKit

@MainActor
final class MacPointPresetSliderTests: XCTestCase {
    func testNativeMacSliderRetainsFractionalKerningPresets() {
        var selected: Double?
        let control = MacPointPresetControl(presets: PointPresetScale.macKerning, current: 0,
            title: "Kerning", identifier: "fixture.kerning") { selected = $0 }
        XCTAssertTrue(control.slider.allowsTickMarkValuesOnly)
        XCTAssertEqual(control.slider.numberOfTickMarks, 6)
        control.slider.doubleValue = 2
        control.slider.sendAction(control.slider.action, to: control.slider.target)
        XCTAssertEqual(selected, 0.5)
    }
}
#endif
