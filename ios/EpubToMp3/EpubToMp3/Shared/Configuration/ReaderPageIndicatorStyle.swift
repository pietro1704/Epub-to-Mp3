import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// How the paginated reader's "x of y" indicator is drawn over the page: a readable pill of the page's own colours.
enum ReaderPageIndicatorStyle {
    struct Appearance {
        let text: PlatformColor
        /// The pill behind the text; `nil` draws the text straight on the page.
        let fill: PlatformColor?
    }

    /// A pill that contrasts with the page whatever the theme: dark with light text over a light page, light with
    /// dark text over a dark page (the page's own foreground can be too close to its background, e.g. Auto in dark).
    static func appearance(background: PlatformColor, foreground: PlatformColor) -> Appearance {
        #if canImport(UIKit)
        func isLight(_ trait: UITraitCollection) -> Bool {
            let c = rgba(background, dark: trait.userInterfaceStyle == .dark)
            return luminance(c) > 0.4
        }
        return Appearance(
            text: UIColor { isLight($0) ? .white : .black },
            fill: UIColor { isLight($0) ? UIColor.black.withAlphaComponent(0.78) : UIColor.white.withAlphaComponent(0.88) })
        #else
        func isLight(_ appearance: NSAppearance) -> Bool {
            luminance(rgba(background, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)) > 0.4
        }
        return Appearance(
            text: NSColor(name: nil) { isLight($0) ? .white : .black },
            fill: NSColor(name: nil) { isLight($0) ? NSColor.black.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.88) })
        #endif
    }

    /// WCAG contrast ratio of `text` over `fill` (itself over `page`), in light or dark appearance.
    static func contrastRatio(of appearance: Appearance, over page: PlatformColor, dark: Bool) -> Double {
        let pageRGBA = rgba(page, dark: dark)
        let fill = appearance.fill.map { composite(rgba($0, dark: dark), over: pageRGBA) } ?? pageRGBA
        let text = composite(rgba(appearance.text, dark: dark), over: fill)
        let a = luminance(text), b = luminance(fill)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    private static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        let alpha = top.a + bottom.a * (1 - top.a)
        func mix(_ t: Double, _ b: Double) -> Double { alpha > 0 ? (t * top.a + b * bottom.a * (1 - top.a)) / alpha : 0 }
        return (mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b), alpha)
    }

    private static func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private static func rgba(_ color: PlatformColor, dark: Bool) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        #endif
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
