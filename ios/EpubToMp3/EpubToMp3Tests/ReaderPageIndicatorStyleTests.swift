import XCTest
@testable import EpubToMp3

/// READER-CHROME-CLIP: the page indicator ("x of y") must be readable over the page in every theme.
@MainActor
final class ReaderPageIndicatorStyleTests: XCTestCase {
    func testThePageIndicatorMeetsWCAGContrastInEveryThemeAndAppearance() throws {
        let suite = "indicator-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var failures: [String] = []
        for theme in ReaderTheme.allCases {
            settings.readerTheme = theme
            for dark in [false, true] {
                let colors = settings.readerColors
                let appearance = ReaderPageIndicatorStyle.appearance(background: colors.background, foreground: colors.foreground)
                let ratio = ReaderPageIndicatorStyle.contrastRatio(of: appearance, over: colors.background, dark: dark)
                if ratio < 4.5 { failures.append("\(theme.rawValue)/\(dark ? "dark" : "light"): \(String(format: "%.2f", ratio))") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "Indicator contrast below 4.5:1 — \(failures)")
    }
}
