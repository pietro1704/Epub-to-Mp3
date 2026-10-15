import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

/// Exercise production palettes rather than a separate table of sample colors.
final class ReaderThemeContrastTests: XCTestCase {
    private func channels(_ color: PlatformColor, dark: Bool) -> [Double] {
        #if canImport(UIKit)
        let color = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
        #else
        var rgb: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            rgb = NSColor(cgColor: color.cgColor)?.usingColorSpace(.sRGB)
        }
        return [Double(rgb!.redComponent), Double(rgb!.greenComponent), Double(rgb!.blueComponent)]
        #endif
    }

    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    @MainActor
    func testActualNamedPalettesHaveReadableBodyContrastInBothHostAppearances() {
        let suite = "ReaderContrast-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for theme in ReaderTheme.allCases where theme != .custom {
            settings.readerTheme = theme
            for dark in [false, true] {
                let colors = settings.readerColors
                let background = luminance(channels(colors.background, dark: dark))
                let foreground = luminance(channels(colors.foreground, dark: dark))
                let contrast = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 7, "\(theme.rawValue), host dark=\(dark)")
            }
        }
    }

    @MainActor
    func testLinkUsesNativeSemanticColorForChosenAppearance() {
        let suite = "ReaderLink-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for theme in ReaderTheme.allCases {
            settings.readerTheme = theme
            for dark in [false, true] {
                let selectedDark = settings.readerPreferredColorScheme.map { $0 == .dark } ?? dark
                #if canImport(UIKit)
                let expected = UIColor.link
                #else
                let expected = NSColor.linkColor
                #endif
                XCTAssertEqual(channels(settings.readerColors.link, dark: dark),
                               channels(expected, dark: selectedDark), "\(theme.rawValue)")
            }
        }
    }

    @MainActor
    func testCustomPaletteKeepsUserColorsAndInfersControlAppearance() {
        let suite = "ReaderCustom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .custom
        settings.readerCustomColors = (background: (0.1, 0.2, 0.3), foreground: (0.9, 0.8, 0.7))
        XCTAssertEqual(settings.readerPreferredColorScheme, .dark)
        for (actual, expected) in zip(channels(settings.readerColors.background, dark: false), [0.1, 0.2, 0.3]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
        settings.readerCustomColors = (background: (1, 1, 1), foreground: (0, 0, 0))
        XCTAssertEqual(settings.readerPreferredColorScheme, .light)
    }
}
