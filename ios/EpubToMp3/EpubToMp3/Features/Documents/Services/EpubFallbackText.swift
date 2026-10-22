import Foundation

enum EpubFallbackText {
    static func firstHeading(in html: String) -> String? {
        guard let match = html.range(of: #"(?is)<h[1-6][^>]*>.*?</h[1-6]>"#, options: .regularExpression) else {
            return nil
        }
        let text = stripHTML(String(html[match])).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - HTML stripping

    /// Strip HTML tags + decode common entities. Preserves paragraph
    /// breaks (block elements → newline). Not a full sanitizer; we
    /// just want readable plain text for TTS / fallback display.
    static func stripHTML(_ html: String) -> String {
        // Pre-clean EPUB artifacts before tag stripping:
        // 1. BOM / zero-width no-break space (\u{FEFF})
        // 2. Non-breaking space numeric entities → regular space
        // 3. JS serialisation artifact from broken renderers
        let html = html
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&#xA0;", with: " ")
            .replacingOccurrences(of: "[object Object]", with: "")

        var output = ""
        var inTag = false
        var inScript = false
        var inStyle = false
        var tagBuffer = ""
        // Whitespace normalization folded into the same pass instead of
        // `NSRegularExpression`-based `replacingOccurrences` calls over
        // the *entire* chapter afterward. A single spine item whose HTML
        // is several MB (the known "footnote-container chapter = entire
        // book" shape — see CLAUDE.md's "Oversized chapter detection"
        // note) drove ICU's regex engine to a multi-GB EXC_RESOURCE
        // crash; the Python pipeline has MAX_CHAPTER_CHARS to guard
        // against that shape, this fallback parser must not need it.
        // Linear character counting has no such blowup regardless of
        // input size.
        var spaceRun = 0
        var newlineRun = 0

        // Block elements that should produce a paragraph break when
        // closed. Order matches HTML5 spec's flow content.
        let blockElements: Set<String> = [
            "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6",
            "li", "blockquote", "pre", "hr", "tr", "section", "article"
        ]

        for ch in html {
            if ch == "<" {
                inTag = true
                tagBuffer = ""
            } else if ch == ">" && inTag {
                inTag = false
                let tag = tagBuffer.lowercased().trimmingCharacters(in: .whitespaces)
                let closing = tag.hasPrefix("/")
                let nameStart = closing ? tag.index(after: tag.startIndex) : tag.startIndex
                let nameEnd = tag[nameStart...].firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? tag.endIndex
                let tagName = String(tag[nameStart..<nameEnd])

                if tagName == "script" { inScript = !closing }
                else if tagName == "style" { inStyle = !closing }
                else if blockElements.contains(tagName) {
                    if newlineRun == 0 {
                        output.append("\n")
                        newlineRun = 1
                    }
                    spaceRun = 0
                }
                tagBuffer = ""
            } else if inTag {
                tagBuffer.append(ch)
            } else if !inScript && !inStyle {
                if ch == " " || ch == "\t" {
                    spaceRun += 1
                    newlineRun = 0
                    if spaceRun == 1 { output.append(" ") }
                } else if ch == "\n" {
                    newlineRun += 1
                    spaceRun = 0
                    if newlineRun <= 2 { output.append("\n") }
                } else {
                    output.append(ch)
                    spaceRun = 0
                    newlineRun = 0
                }
            }
        }

        return decodeEntities(output)
    }

    /// Decode the handful of HTML entities that actually appear in
    /// EPUBs. Full XML entity table is overkill — we cover the ones
    /// that matter for readability.
    fileprivate static func decodeEntities(_ s: String) -> String {
        let replacements: [Substring: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
            "&ndash;": "–", "&mdash;": "—",
            "&ldquo;": "“", "&rdquo;": "”",
            "&lsquo;": "‘", "&rsquo;": "’",
            "&hellip;": "…",
        ]

        // Decode in one linear pass. Replacing each entity across the whole
        // string creates a new full-size String per map entry and can briefly
        // retain several copies of a multi-megabyte chapter.
        var result = String()
        result.reserveCapacity(s.utf8.count)
        var cursor = s.startIndex
        while cursor < s.endIndex {
            guard let ampersand = s[cursor...].firstIndex(of: "&"),
                  let semicolon = s[ampersand...].firstIndex(of: ";") else {
                result.append(contentsOf: s[cursor...])
                break
            }
            result.append(contentsOf: s[cursor..<ampersand])
            let entity = s[ampersand...semicolon]
            if let replacement = replacements[entity] {
                result.append(contentsOf: replacement)
            } else {
                result.append(contentsOf: entity)
            }
            cursor = s.index(after: semicolon)
        }
        return result
    }
}
