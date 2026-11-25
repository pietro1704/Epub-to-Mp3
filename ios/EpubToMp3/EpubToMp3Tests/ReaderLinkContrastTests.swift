import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

/// CONTRAST-AUDIT area 1 (Apple): reader links meet WCAG 2.2 AA (4.5:1) on every reader background, in every host
/// environment (light, dark, Increase Contrast). Measured 2026-11-24: sepia 4.33 and parchment 3.74 before the fix.
@MainActor
final class ReaderLinkContrastTests: XCTestCase {
    func testLinksMeetAAOnEveryNamedReaderTheme() {
        let suite = "ReaderLinkContrast-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for theme in ReaderTheme.allCases where theme != .custom {
            settings.readerTheme = theme
            let colors = settings.readerColors
            for environment in ContrastAudit.environments {
                let ratio = ContrastAudit.ratio(colors.link, over: colors.background, in: environment)
                XCTAssertGreaterThanOrEqual(ratio, ContrastAudit.text, "\(theme.rawValue) link, \(environment)")
            }
        }
    }

    func testLinksMeetAAOnUserChosenBackgrounds() {
        let suite = "ReaderLinkCustom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .custom
        let backgrounds: [(Double, Double, Double)] = [(0.90, 0.85, 0.72), (0.2, 0.3, 0.9), (0.95, 0.55, 0.15), (0.4, 0.4, 0.4), (0.05, 0.1, 0.4)]
        for background in backgrounds {
            settings.readerCustomColors = (background: background, foreground: (0, 0, 0))
            let colors = settings.readerColors
            for environment in ContrastAudit.environments {
                let ratio = ContrastAudit.ratio(colors.link, over: colors.background, in: environment)
                XCTAssertGreaterThanOrEqual(ratio, ContrastAudit.text, "custom background \(background), \(environment)")
            }
        }
    }
}
