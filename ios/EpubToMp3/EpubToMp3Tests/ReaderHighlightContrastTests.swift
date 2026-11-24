import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

/// CONTRAST-AUDIT area 2 (Apple): text stays WCAG AA under the spoken word/sentence highlight in every reader theme and
/// host environment, without dimming the highlight where it already passes.
@MainActor
final class ReaderHighlightContrastTests: XCTestCase {
    private func rgb(_ color: PlatformColor, _ environment: ContrastAudit.Environment) -> WCAGContrast.RGB {
        let c = ContrastAudit.resolve(color, in: environment)
        return (c.r, c.g, c.b)
    }

    func testTextOnTheSpokenHighlightMeetsAAInEveryThemeAndEnvironment() {
        let suite = "HighlightContrast-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for theme in ReaderTheme.allCases where theme != .custom {
            settings.readerTheme = theme
            let colors = settings.readerColors
            for environment in ContrastAudit.environments {
                let background = rgb(colors.background, environment)
                let text = rgb(colors.foreground, environment)
                let tint = rgb(.systemYellow, environment)
                for preferred in [0.20, 0.65] {
                    let alpha = ReaderHighlightContrast.alpha(preferred: preferred, tint: tint, text: text, background: background)
                    let shown = ReaderHighlightContrast.composite(tint: tint, alpha: alpha, over: background)
                    XCTAssertGreaterThanOrEqual(WCAGContrast.ratio(text, shown), ContrastAudit.text,
                                                "\(theme.rawValue) α\(preferred) -> \(alpha), \(environment)")
                    XCTAssertLessThanOrEqual(alpha, preferred)
                    let untouched = ReaderHighlightContrast.composite(tint: tint, alpha: preferred, over: background)
                    if WCAGContrast.ratio(text, untouched) >= ContrastAudit.text {
                        XCTAssertEqual(alpha, preferred, accuracy: 0.0001, "No dimming where it already passes: \(theme.rawValue), \(environment)")
                    }
                }
            }
        }
    }

    func testTheFloorKeepsAVisibleHighlightEvenWhenNoStrengthPasses() {
        // Mid-grey text on mid-grey background can never reach 4.5:1: the highlight stays at the floor, not zero.
        let grey: WCAGContrast.RGB = (0.5, 0.5, 0.5)
        let alpha = ReaderHighlightContrast.alpha(preferred: 0.65, tint: (1, 0.8, 0), text: grey, background: grey)
        XCTAssertEqual(alpha, ReaderHighlightContrast.minimumAlpha, accuracy: 0.0001)
    }
}
