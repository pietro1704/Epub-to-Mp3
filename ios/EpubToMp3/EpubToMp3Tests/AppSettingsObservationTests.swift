import XCTest
import Observation
@testable import EpubToMp3

/// Regression for the long-standing bug where toolbar pickers in
/// `ReaderView` looked dead until the next page-turn: the previous
/// `@AppStorage`-on-an-@Observable hybrid only fired observation
/// inside `View` bodies that re-read the wrapper directly, so any
/// nested SwiftUI sub-body (GeometryReader, the menu sheet, etc.)
/// kept seeing stale values.
///
/// Each test below subscribes to `withObservationTracking { _ = s.field }`
/// and asserts the change handler fires exactly once when the
/// property mutates. If any case regresses, the reader UI will stop
/// repainting on toolbar changes.
final class AppSettingsObservationTests: XCTestCase {

    private func makeSettings() -> AppSettings {
        // Suite-name UUID guarantees a clean slate per test so we
        // never observe a value coming back from a sibling test.
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return AppSettings(defaults: defaults)
    }

    private func observe<T>(
        _ keyPath: KeyPath<AppSettings, T>,
        on settings: AppSettings,
        message: String,
        mutate: () -> Void
    ) {
        let exp = expectation(description: message)
        withObservationTracking {
            _ = settings[keyPath: keyPath]
        } onChange: {
            exp.fulfill()
        }
        mutate()
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: Core typography

    func testReaderFontSizeChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerFontSize, on: s, message: "fontSize observed") {
            s.readerFontSize = 3
        }
    }

    func testReaderFontFamilyChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerFontFamily, on: s, message: "fontFamily observed") {
            s.readerFontFamily = .mono
        }
    }

    func testReaderThemeChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerTheme, on: s, message: "theme observed") {
            s.readerTheme = .sepia
        }
    }

    func testReaderLayoutChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLayout, on: s, message: "layout observed") {
            s.readerLayout = .paginated
        }
    }

    func testReaderLineSpacingChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLineSpacing, on: s, message: "lineSpacing observed") {
            s.readerLineSpacing = 12
        }
    }

    func testReaderMarginChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerMargin, on: s, message: "margin observed") {
            s.readerMargin = 48
        }
    }

    func testReaderColumnWidthChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerColumnWidth, on: s, message: "columnWidth observed") {
            s.readerColumnWidth = 820
        }
    }

    // MARK: Override knobs

    func testReaderBoldOverrideChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerBoldOverride, on: s, message: "boldOverride observed") {
            s.readerBoldOverride = true
        }
    }

    func testReaderLetterSpacingChangeFiresObservation() {
        let s = makeSettings()
        observe(\.readerLetterSpacing, on: s, message: "letterSpacing observed") {
            s.readerLetterSpacing = 1.5
        }
    }

    // MARK: Persistence — values survive an AppSettings re-init
    //
    // Critical: `@Observable` + `didSet` UserDefaults writes must
    // round-trip cleanly. A bug here used to drop every reader pref
    // on app relaunch.

    func testReaderFieldsPersistAcrossInstances() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!

        do {
            let s = AppSettings(defaults: defaults)
            s.readerFontSize = 4
            s.readerFontFamily = .mono
            s.readerTheme = .dark
            s.readerLineSpacing = 14
            s.readerMargin = 36
            s.readerColumnWidth = 640
            s.readerBoldOverride = true
            s.readerLetterSpacing = 2.0
        }

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.readerFontSize, 4)
        XCTAssertEqual(reloaded.readerFontFamily, .mono)
        XCTAssertEqual(reloaded.readerTheme, .dark)
        XCTAssertEqual(reloaded.readerLineSpacing, 14, accuracy: 0.001)
        XCTAssertEqual(reloaded.readerMargin, 36, accuracy: 0.001)
        XCTAssertEqual(reloaded.readerColumnWidth, 640, accuracy: 0.001)
        XCTAssertTrue(reloaded.readerBoldOverride)
        XCTAssertEqual(reloaded.readerLetterSpacing, 2.0, accuracy: 0.001)
    }

    // MARK: restoreOriginal()

    func testRestoreOriginalResetsAllOverrideFields() {
        let s = makeSettings()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        s.readerLetterSpacing = 2
        s.readerWordSpacing = 3
        // Preserved preferences (not in the override reset set):
        s.readerTheme = .dark
        s.readerFontFamily = .mono
        s.readerLineSpacing = 12

        s.restoreOriginal()

        XCTAssertFalse(s.readerOverrideFontFamily)
        XCTAssertFalse(s.readerOverrideFontSize)
        XCTAssertFalse(s.readerOverrideColours)
        XCTAssertFalse(s.readerBoldOverride)
        XCTAssertFalse(s.readerSuppressItalic)
        XCTAssertEqual(s.readerLetterSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
        // Preserved
        XCTAssertEqual(s.readerTheme, .dark)
        XCTAssertEqual(s.readerFontFamily, .mono)
        XCTAssertEqual(s.readerLineSpacing, 12, accuracy: 0.001)
    }
}
