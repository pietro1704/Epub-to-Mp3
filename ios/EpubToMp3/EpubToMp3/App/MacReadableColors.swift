#if os(macOS)
import AppKit

extension NSColor {
    /// Secondary text that stays legible: the system `secondaryLabelColor` reads 3.8:1 in the light appearance
    /// (below the 4.5:1 WCAG AA minimum for small text). Light uses a solid gray that reaches at least 5:1 on the
    /// window, list and header backgrounds; dark keeps the system color, which already exceeds 5:1.
    static let readableSecondaryLabel = NSColor(name: "readableSecondaryLabel") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .secondaryLabelColor : NSColor(srgbRed: 90 / 255, green: 90 / 255, blue: 94 / 255, alpha: 1)
    }
}
#endif
