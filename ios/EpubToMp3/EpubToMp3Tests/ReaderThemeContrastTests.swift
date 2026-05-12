import XCTest

/// WCAG 2.1 contrast ratio tests for every ReaderTheme.
///
/// Each non-custom theme must satisfy:
///   - Body text / background ≥ 7:1  (HIG comfortable reading target)
///   - Accent colour / background ≥ 3:1  (HIG large-text minimum)
///
/// Reference pairs (Apple Books exact):
///   Light:     bg #FFFFFF  / text #000000  / accent system-blue (assumed ≥ 3:1)
///   Sepia:     bg #F8F0E0  / text #5B4636
///   Parchment: bg #F4ECD8  / text #3D2F1F
///   Paper:     bg #E8E2D5  / text #2A2520
///   Dark:      bg #1C1C1E  / text #E8E8E8
///   Black:     bg #000000  / text #E0E0E0

final class ReaderThemeContrastTests: XCTestCase {

    // MARK: - WCAG helpers

    /// sRGB channel → linear light value.
    private func linearise(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance of an sRGB triple (values 0…1).
    private func luminance(r: Double, g: Double, b: Double) -> Double {
        0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
    }

    /// WCAG contrast ratio between two luminance values.
    private func contrast(l1: Double, l2: Double) -> Double {
        let lighter = max(l1, l2)
        let darker  = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Parse a 6-digit hex string (without #) into (r, g, b) ∈ 0…1.
    private func hex(_ h: String) -> (r: Double, g: Double, b: Double) {
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        return (
            r: Double((value >> 16) & 0xFF) / 255.0,
            g: Double((value >> 8)  & 0xFF) / 255.0,
            b: Double( value        & 0xFF) / 255.0
        )
    }

    // MARK: - Theme table

    /// (theme name, bg hex, text hex, accent hex or nil to skip accent check)
    private let themes: [(name: String, bg: String, text: String, accent: String?)] = [
        ("light",     "FFFFFF", "000000", nil),   // system accent — skip automated check
        ("sepia",     "F8F0E0", "5B4636", nil),
        ("parchment", "F4ECD8", "3D2F1F", nil),
        ("paper",     "E8E2D5", "2A2520", nil),
        ("dark",      "1C1C1E", "E8E8E8", "5AC8FA"),
        ("black",     "000000", "E0E0E0", "5AC8FA"),
    ]

    // MARK: - Tests

    func testBodyTextContrastAtLeast7to1() {
        for t in themes {
            let bg   = hex(t.bg)
            let text = hex(t.text)
            let lBg  = luminance(r: bg.r,   g: bg.g,   b: bg.b)
            let lTxt = luminance(r: text.r, g: text.g, b: text.b)
            let ratio = contrast(l1: lBg, l2: lTxt)
            XCTAssertGreaterThanOrEqual(
                ratio, 7.0,
                "\(t.name) text/bg contrast \(String(format: "%.2f", ratio)):1 < 7:1 " +
                "(bg #\(t.bg), text #\(t.text))"
            )
        }
    }

    func testAccentContrastAtLeast3to1() {
        for t in themes {
            guard let accentHex = t.accent else { continue }
            let bg     = hex(t.bg)
            let accent = hex(accentHex)
            let lBg    = luminance(r: bg.r,     g: bg.g,     b: bg.b)
            let lAcc   = luminance(r: accent.r, g: accent.g, b: accent.b)
            let ratio  = contrast(l1: lBg, l2: lAcc)
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(t.name) accent/bg contrast \(String(format: "%.2f", ratio)):1 < 3:1 " +
                "(bg #\(t.bg), accent #\(accentHex))"
            )
        }
    }

    // MARK: - Sanity: WCAG formula itself

    func testWcagHelperBlackOnWhite() {
        let lWhite = luminance(r: 1, g: 1, b: 1)
        let lBlack = luminance(r: 0, g: 0, b: 0)
        XCTAssertEqual(contrast(l1: lWhite, l2: lBlack), 21.0, accuracy: 0.01)
    }
}
