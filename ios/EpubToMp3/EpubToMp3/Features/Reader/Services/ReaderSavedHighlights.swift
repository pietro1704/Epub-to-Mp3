import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ReaderSavedHighlights {
    private static let marker = NSAttributedString.Key("epub.userHighlight")
    private static let originalBackground = NSAttributedString.Key("epub.userHighlight.originalBackground")

    static func target(at selection: NSRange, highlights: [Bookmark], in text: NSAttributedString) -> Bookmark? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location < text.length, selection.length <= text.length - selection.location else { return nil }
        return highlights.filter(\.isHighlight).first { bookmark in
            guard let range = range(for: bookmark, in: text) else { return false }
            return NSIntersectionRange(selection, range).length > 0
        }
    }

    static func range(for bookmark: Bookmark, in text: NSAttributedString) -> NSRange? {
        ReaderTextHighlight.range(for: SentenceSpan(id: bookmark.id.uuidString, text: bookmark.selectedText,
            startChar: bookmark.startChar, endChar: bookmark.endChar), in: text)
    }

    /// Restore original book backgrounds before repainting the remaining annotations.
    /// Transient playback highlighting is painted separately by the layout manager.
    static func repaint(_ text: NSAttributedString, highlights: [Bookmark]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(originalBackground, in: full) { value, range, _ in
            guard let value else { return }
            if value is NSNull { result.removeAttribute(.backgroundColor, range: range) }
            else { result.addAttribute(.backgroundColor, value: value, range: range) }
        }
        result.removeAttribute(marker, range: full)
        result.removeAttribute(originalBackground, range: full)
        for bookmark in highlights where bookmark.isHighlight {
            guard let range = range(for: bookmark, in: result) else { continue }
            result.enumerateAttributes(in: range) { attributes, run, _ in
                guard attributes[originalBackground] == nil else { return }
                result.addAttribute(originalBackground, value: attributes[.backgroundColor] ?? NSNull(), range: run)
            }
            result.addAttribute(marker, value: bookmark.id.uuidString, range: range)
            result.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
        return result
    }

    static func playbackRatio(selection: NSRange, rendered: String, source: String) -> Double? {
        guard let mapped = ReaderAnchorRange.sourceRange(rendered: rendered, selection: selection, in: source),
              let range = Range(mapped, in: source), !source.isEmpty else { return nil }
        // The playback bridge floors ratio * source length. Bias one ULP upward
        // so floating-point division cannot select the preceding source scalar.
        return (Double(source[..<range.lowerBound].unicodeScalars.count) / Double(source.unicodeScalars.count)).nextUp
    }
}
