import Foundation

/// Maps absolute CSS lengths onto the Cocoa HTML importer's coordinate space.
///
/// The UIKit/AppKit importer treats one CSS `px` as one native point and
/// scales the other absolute units at 96 px per inch, so `18pt` imports as a
/// 24-point font. Publisher CSS units are authoritative in the reader: a CSS
/// point is a native point and a CSS pixel is 0.75 point. Rewriting absolute
/// lengths to importer pixels that already hold the point value keeps both
/// true. Relative units (`em`, `rem`, `%`, keywords) are unchanged: the
/// importer's 12-point `medium` already equals CSS `16px`.
///
/// Only the importer input is rewritten. Structural paragraph geometry and
/// reader overrides continue to read the publisher's original CSS.
enum EpubCssLengths {
    /// Native points for an absolute CSS length, or `nil` for relative units.
    static func points(_ value: Double, unit: String) -> Double? {
        pointsPerUnit[unit.lowercased()].map { value * $0 }
    }

    /// Rewrites absolute lengths in a stylesheet or a `style` attribute value.
    /// Comments, `url(...)`, quoted strings, attribute selectors and at-rule
    /// preludes (media queries keep the importer's own viewport units) are
    /// preserved verbatim.
    static func importerCSS(_ css: String) -> String {
        replace(lengthPattern, in: css) { match, source in
            let original = source.substring(with: match.range)
            guard match.range(at: 1).location == NSNotFound,
                  let number = Double(source.substring(with: match.range(at: 2))),
                  let value = points(number, unit: source.substring(with: match.range(at: 3))),
                  let formatted = format(value) else { return original }
            return "\(formatted)px"
        }
    }

    /// Rewrites the `style` attribute values inside the tags of an HTML
    /// fragment. Text content is never changed.
    static func importerHTML(_ html: String) -> String {
        replace(tagPattern, in: html) { tag, source in
            let markup = source.substring(with: tag.range)
            return replace(styleAttributePattern, in: markup) { style, attribute in
                let quoted = style.range(at: 3).location != NSNotFound
                let value = attribute.substring(with: style.range(at: quoted ? 3 : 4))
                let quote = quoted ? attribute.substring(with: style.range(at: 2)) : ""
                return attribute.substring(with: style.range(at: 1)) + quote + importerCSS(value) + quote
            }
        }
    }

    private static let pointsPerUnit: [String: Double] = [
        "pt": 1, "px": 0.75, "pc": 12, "in": 72, "cm": 72 / 2.54, "mm": 72 / 25.4,
    ]

    private static let lengthPattern = try! NSRegularExpression(pattern: #"""
        (?is)(/\*.*?\*/|url\(\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^)]*)\s*\)|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]|@[a-z-]+[^{;]*)|(?<![\w.#-])([+-]?(?:\d+\.?\d*|\.\d+))(pt|px|pc|in|cm|mm)(?![\w-])
        """#)

    private static let tagPattern = try! NSRegularExpression(pattern: "(?s)<[A-Za-z][^>]*>")

    private static let styleAttributePattern = try! NSRegularExpression(
        pattern: #"(?is)(\bstyle\s*=\s*)(?:(["'])(.*?)\2|([^\s"'>]+))"#
    )

    private static func format(_ value: Double) -> String? {
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        with transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, source)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}
