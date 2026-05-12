import XCTest
@testable import EpubToMp3

/// Integration tests for theme propagation contracts.
///
/// Verifies:
///   1. `preferredColorScheme` returns the correct value for every named theme.
///   2. Dark / Black themes → `.dark`; warm / light themes → `.light`; custom → `nil`.
///
/// These tests are logic-only (no SwiftUI rendering) so they run on any
/// host without a simulator.
final class ReaderThemeIntegrationTests: XCTestCase {

    // MARK: - preferredColorScheme mapping

    func testDarkThemePrefersDarkColorScheme() {
        XCTAssertEqual(ReaderTheme.dark.preferredColorScheme, .dark,
                       "Dark theme must force .dark so reader controls match the background.")
    }

    func testBlackThemePrefersDarkColorScheme() {
        XCTAssertEqual(ReaderTheme.black.preferredColorScheme, .dark,
                       "Black theme must force .dark — OLED black with light controls looks broken.")
    }

    func testLightThemePrefersLightColorScheme() {
        XCTAssertEqual(ReaderTheme.light.preferredColorScheme, .light,
                       "Light theme must force .light to stay readable when OS is in dark mode.")
    }

    func testSepiaThemePrefersLightColorScheme() {
        XCTAssertEqual(ReaderTheme.sepia.preferredColorScheme, .light,
                       "Sepia is a warm-light theme; controls must not go dark.")
    }

    func testParchmentThemePrefersLightColorScheme() {
        XCTAssertEqual(ReaderTheme.parchment.preferredColorScheme, .light,
                       "Parchment is a warm-light theme; controls must not go dark.")
    }

    func testPaperThemePrefersLightColorScheme() {
        XCTAssertEqual(ReaderTheme.paper.preferredColorScheme, .light,
                       "Paper is a warm-light theme; controls must not go dark.")
    }

    func testCustomThemeReturnsNilColorScheme() {
        XCTAssertNil(ReaderTheme.custom.preferredColorScheme,
                     "Custom theme defers to the OS — we don't know if user colours are dark or light.")
    }

    // MARK: - Exhaustive coverage

    func testAllThemesHaveADefinedPreferredColorScheme() {
        // If a new theme case is added without updating `preferredColorScheme`,
        // this test will fail only if the switch is non-exhaustive and the
        // author forgets to add a case. The test acts as a reminder.
        for theme in ReaderTheme.allCases {
            // Calling the property must not crash.
            _ = theme.preferredColorScheme
        }
    }

    // MARK: - Dark theme group

    func testDarkThemeGroupIsDark() {
        let darkThemes: [ReaderTheme] = [.dark, .black]
        for theme in darkThemes {
            XCTAssertEqual(
                theme.preferredColorScheme, .dark,
                "\(theme.rawValue) must map to .dark"
            )
        }
    }

    func testLightThemeGroupIsLight() {
        let lightThemes: [ReaderTheme] = [.light, .sepia, .parchment, .paper]
        for theme in lightThemes {
            XCTAssertEqual(
                theme.preferredColorScheme, .light,
                "\(theme.rawValue) must map to .light"
            )
        }
    }

    // MARK: - AppSettings persistence round-trip

    func testReaderThemePersistsAndReloads() {
        let suite = "readerThemeIntegration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .dark
        XCTAssertEqual(defaults.string(forKey: "readerTheme"), "dark")

        // Reload from same defaults.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.readerTheme, .dark)
        XCTAssertEqual(reloaded.readerTheme.preferredColorScheme, .dark)
    }

    func testReaderThemeDefaultsToLight() {
        let suite = "readerThemeIntegration.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.readerTheme, .light,
                       "Fresh install must default to Light theme.")
    }
}
