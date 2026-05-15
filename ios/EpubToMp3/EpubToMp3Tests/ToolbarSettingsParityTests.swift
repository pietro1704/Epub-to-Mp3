import XCTest
@testable import EpubToMp3

final class ToolbarSettingsParityTests: XCTestCase {
    private func make() -> (AppSettings, UserDefaults) {
        let suite = "Toolbar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: d), d)
    }

    func testFontSizeStepperBoundaries() {
        let (s, _) = make()
        s.readerFontSize = 0
        s.readerFontSize = max(0, s.readerFontSize - 1)
        XCTAssertEqual(s.readerFontSize, 0)
        s.readerFontSize = 4
        s.readerFontSize = min(4, s.readerFontSize + 1)
        XCTAssertEqual(s.readerFontSize, 4)
    }

    func testFontFamilyPickerAllCasesPersist() {
        let (s, d) = make()
        for f in ReaderFontFamily.allCases {
            s.readerFontFamily = f
            XCTAssertEqual(AppSettings(defaults: d).readerFontFamily, f)
        }
    }

    func testThemePickerAllCasesPersist() {
        let (s, d) = make()
        for t in ReaderTheme.allCases {
            s.readerTheme = t
            XCTAssertEqual(AppSettings(defaults: d).readerTheme, t)
        }
    }

    func testLayoutPickerAllCasesPersist() {
        let (s, d) = make()
        for l in ReaderLayout.allCases {
            s.readerLayout = l
            XCTAssertEqual(AppSettings(defaults: d).readerLayout, l)
        }
    }

    func testLineSpacingDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [0.0, 4.0, 6.0, 8.0, 12.0, 16.0] {
            s.readerLineSpacing = v
            XCTAssertEqual(AppSettings(defaults: d).readerLineSpacing, v, accuracy: 0.001)
        }
    }

    func testMarginDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [16.0, 24.0, 36.0, 48.0, 64.0] {
            s.readerMargin = v
            XCTAssertEqual(AppSettings(defaults: d).readerMargin, v, accuracy: 0.001)
        }
    }

    func testColumnWidthDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [520.0, 640.0, 720.0, 820.0, 920.0] {
            s.readerColumnWidth = v
            XCTAssertEqual(AppSettings(defaults: d).readerColumnWidth, v, accuracy: 0.001)
        }
    }

    func testAutoScrollTogglesBackAndForth() {
        let (s, _) = make()
        s.readerAutoScroll = true
        XCTAssertTrue(s.readerAutoScroll)
        s.readerAutoScroll = false
        XCTAssertFalse(s.readerAutoScroll)
    }

    func testEveryOverrideFlagToggles() {
        let (s, _) = make()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        XCTAssertTrue(s.readerOverrideFontFamily)
        XCTAssertTrue(s.readerOverrideFontSize)
        XCTAssertTrue(s.readerOverrideColours)
        XCTAssertTrue(s.readerBoldOverride)
        XCTAssertTrue(s.readerSuppressItalic)
    }

    func testLetterSpacingClampsAndPersists() {
        let (s, d) = make()
        s.readerLetterSpacing = 99
        XCTAssertEqual(s.readerLetterSpacing, 4, accuracy: 0.001)
        s.readerLetterSpacing = -99
        XCTAssertEqual(s.readerLetterSpacing, -2, accuracy: 0.001)
        s.readerLetterSpacing = 1.5
        XCTAssertEqual(AppSettings(defaults: d).readerLetterSpacing, 1.5, accuracy: 0.001)
    }

    func testWordSpacingClampsAndPersists() {
        let (s, d) = make()
        s.readerWordSpacing = 999
        XCTAssertEqual(s.readerWordSpacing, 8, accuracy: 0.001)
        s.readerWordSpacing = -5
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
        s.readerWordSpacing = 3
        XCTAssertEqual(AppSettings(defaults: d).readerWordSpacing, 3, accuracy: 0.001)
    }

    func testRestoreOriginalClearsAllOverrides() {
        let (s, _) = make()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        s.readerLetterSpacing = 2
        s.readerWordSpacing = 4
        s.restoreOriginal()
        XCTAssertFalse(s.readerOverrideFontFamily)
        XCTAssertFalse(s.readerOverrideFontSize)
        XCTAssertFalse(s.readerOverrideColours)
        XCTAssertFalse(s.readerBoldOverride)
        XCTAssertFalse(s.readerSuppressItalic)
        XCTAssertEqual(s.readerLetterSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
    }

    func testRestoreOriginalDoesNotTouchPreferenceFields() {
        let (s, _) = make()
        s.readerLayout = .paginated
        s.readerTheme = .sepia
        s.readerAutoScroll = false
        s.backendURL = "http://my-backend"
        s.readerOverrideFontFamily = true
        s.restoreOriginal()
        XCTAssertEqual(s.readerLayout, .paginated)
        XCTAssertEqual(s.readerTheme, .sepia)
        XCTAssertFalse(s.readerAutoScroll)
        XCTAssertEqual(s.backendURL, "http://my-backend")
        XCTAssertFalse(s.readerOverrideFontFamily)
    }
}
