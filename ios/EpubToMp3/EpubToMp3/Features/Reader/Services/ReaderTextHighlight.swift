import Foundation

/// Resolves a `SentenceSpan`/highlight span's stored character offsets into
/// an `NSRange` inside a specific `NSAttributedString` — the one bridge
/// point where "an offset saved earlier" meets "whatever is on screen now".
///
/// Offsets are looked up primarily by matching `span.text` at the stored
/// `startChar`/`endChar` position; if the underlying string shifted (a
/// highlight created before a font/theme change altered the rendered
/// plain-text layout), it falls back to a plain substring search for
/// `span.text` so a saved highlight/bookmark degrades to "found the right
/// words, slightly wrong position" instead of silently vanishing.
enum ReaderTextHighlight {
    static func range(for id: String?, spans: [SentenceSpan], in content: NSAttributedString) -> NSRange? {
        guard let id, let span = spans.first(where: { $0.id == id }) else { return nil }
        return range(for: span, in: content)
    }

    static func range(for span: SentenceSpan, in content: NSAttributedString) -> NSRange? {
        let full = content.string as NSString
        let candidate = NSRange(location: span.startChar, length: max(0, span.endChar - span.startChar))
        if candidate.location >= 0, candidate.location + candidate.length <= full.length,
           full.substring(with: candidate) == span.text {
            return candidate
        }
        guard !span.text.isEmpty else { return nil }
        let found = full.range(of: span.text)
        return found.location != NSNotFound ? found : nil
    }
}
