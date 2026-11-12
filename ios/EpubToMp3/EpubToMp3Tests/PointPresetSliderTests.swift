import XCTest
@testable import EpubToMp3

final class PointPresetScaleTests: XCTestCase {
    func testAnExistingValueRemainsReachableWithoutChangingStoredPreferences() {
        XCTAssertEqual(PointPresetScale.preserving(23, in: PointPresetScale.font), [14, 17, 20, 23, 24, 28])
        XCTAssertEqual(PointPresetScale.preserving(20, in: PointPresetScale.font), PointPresetScale.font)
    }

    func testIrregularFontScaleKeepsTheExistingNearestChoices() {
        XCTAssertEqual(PointPresetScale.font, [14, 17, 20, 24, 28])
        XCTAssertEqual(PointPresetScale.nearestIndex(to: 23.5, in: PointPresetScale.font), 3)
        XCTAssertEqual(PointPresetScale.nearestIndex(to: -5, in: PointPresetScale.font), 0)
        XCTAssertEqual(PointPresetScale.nearestIndex(to: 100, in: PointPresetScale.font), 4)
    }
}

#if os(iOS)
import UIKit

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
