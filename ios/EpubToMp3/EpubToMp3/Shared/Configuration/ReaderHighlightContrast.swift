import Foundation

/// CONTRAST-AUDIT area 2: the spoken-word and sentence highlight is a translucent tint drawn under the text. The text
/// must stay AA (4.5:1) on the composited colour in every reader theme, so the tint's strength is reduced only as far
/// as needed (a bright yellow at 65% under light text on a dark theme measured 2.9:1).
enum ReaderHighlightContrast {
    static let minimumAlpha = 0.08

    static func alpha(preferred: Double, tint: WCAGContrast.RGB, text: WCAGContrast.RGB,
                      background: WCAGContrast.RGB, minimum: Double = 4.5) -> Double {
        var alpha = preferred
        while alpha > minimumAlpha {
            let shown = composite(tint: tint, alpha: alpha, over: background)
            if WCAGContrast.ratio(text, shown) >= minimum { return alpha }
            alpha -= 0.01
        }
        return minimumAlpha
    }

    static func composite(tint: WCAGContrast.RGB, alpha: Double, over background: WCAGContrast.RGB) -> WCAGContrast.RGB {
        (tint.r * alpha + background.r * (1 - alpha), tint.g * alpha + background.g * (1 - alpha),
         tint.b * alpha + background.b * (1 - alpha))
    }
}
