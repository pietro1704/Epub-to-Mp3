import Foundation

/// WCAG 2.2 contrast maths on sRGB components (0...1), shared by every client of the Apple app.
enum WCAGContrast {
    typealias RGB = (r: Double, g: Double, b: Double)

    static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double {
            let channel = min(1, max(0, v))
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `foreground` unchanged when it already meets `minimum` against `background`; otherwise the closest colour
    /// on the way to black (light backgrounds) or white (dark ones) that does, so the hue is kept as long as possible.
    static func adjusted(_ foreground: RGB, against background: RGB, minimum: Double) -> RGB {
        guard ratio(foreground, background) < minimum else { return foreground }
        let target: RGB = luminance(background) > 0.179 ? (0, 0, 0) : (1, 1, 1)
        var step = 1
        while step <= 50 {
            let t = Double(step) / 50
            let candidate: RGB = (foreground.r + (target.r - foreground.r) * t,
                                  foreground.g + (target.g - foreground.g) * t,
                                  foreground.b + (target.b - foreground.b) * t)
            if ratio(candidate, background) >= minimum { return candidate }
            step += 1
        }
        return target
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension PlatformColor {
    /// sRGB components of an already resolved (non-dynamic) colour, nil when it cannot be expressed in sRGB.
    var srgbComponents: WCAGContrast.RGB? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return getRed(&r, green: &g, blue: &b, alpha: &a) ? (Double(r), Double(g), Double(b)) : nil
        #else
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        #endif
    }
}
