import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

/// CONTRAST-AUDIT (Apple): resolved-colour WCAG 2.2 AA checks of production colours in every host environment:
/// light, dark, and both with Increase Contrast. Measures what is drawn (alpha composited over the real background).
enum ContrastAudit {
    struct Environment: CustomStringConvertible {
        let dark: Bool
        let increasedContrast: Bool
        var description: String { "\(dark ? "dark" : "light")\(increasedContrast ? "+increaseContrast" : "")" }
    }

    struct RGBA { var r: Double, g: Double, b: Double, a: Double }

    static let environments: [Environment] = [
        .init(dark: false, increasedContrast: false), .init(dark: true, increasedContrast: false),
        .init(dark: false, increasedContrast: true), .init(dark: true, increasedContrast: true),
    ]

    static func resolve(_ color: PlatformColor, in environment: Environment) -> RGBA {
        #if canImport(UIKit)
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: environment.dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: environment.increasedContrast ? .high : .normal),
        ])
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
        #else
        let name: NSAppearance.Name = switch (environment.dark, environment.increasedContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        var result = RGBA(r: 0, g: 0, b: 0, a: 1)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let rgb = NSColor(cgColor: color.cgColor)?.usingColorSpace(.sRGB) {
                result = RGBA(r: Double(rgb.redComponent), g: Double(rgb.greenComponent),
                              b: Double(rgb.blueComponent), a: Double(rgb.alphaComponent))
            }
        }
        return result
        #endif
    }

    static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        let a = top.a
        return RGBA(r: top.r * a + bottom.r * (1 - a), g: top.g * a + bottom.g * (1 - a),
                    b: top.b * a + bottom.b * (1 - a), a: 1)
    }

    static func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func ratio(_ foreground: RGBA, over background: RGBA) -> Double {
        let top = composite(foreground, over: background)
        let a = luminance(top), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `alpha` is applied after resolving, so a dynamic colour never freezes in the wrong appearance.
    static func ratio(_ foreground: PlatformColor, alpha: Double, over background: PlatformColor, in environment: Environment) -> Double {
        let back = composite(resolve(background, in: environment), over: RGBA(r: 1, g: 1, b: 1, a: 1))
        var front = resolve(foreground, in: environment)
        front.a *= alpha
        return ratio(front, over: back)
    }

    static func ratio(_ foreground: PlatformColor, over background: PlatformColor, in environment: Environment) -> Double {
        let back = composite(resolve(background, in: environment), over: RGBA(r: 1, g: 1, b: 1, a: 1))
        return ratio(resolve(foreground, in: environment), over: back)
    }

    /// Normal text 4.5:1; large text and UI components/icons 3:1 (WCAG 1.4.3 and 1.4.11).
    static let text = 4.5, component = 3.0
}
