import Foundation

/// Pure-Swift EPUB → `EbookFulltext` fallback parser. Used when the
/// in-process Python pipeline (`PythonBridge.parseEpub`) fails or
/// produces zero chapters — typically on the first device-only run
/// before the embedded interpreter finishes bootstrapping its caches,
/// or when an EPUB uses an OPF dialect the canonical parser refuses
/// (e.g. legacy Sigil exports with non-spec `application/xhtml`
/// item types).
///
/// Strategy: walk the OPF `<spine>` in order, pull each item's HTML
/// out of the ZIP, strip tags, treat the result as one chapter. This
/// loses formatting and structural cues (headings, footnotes, TOC
/// nesting) but is sufficient to put readable text on screen — the
/// alternative is "Couldn't read this book" with zero recourse.
///
/// Never throws: returns an empty `EbookFulltext` (zero chapters) if
/// the EPUB is truly unreadable. Callers decide whether to surface
/// that as an error.
enum EpubFallbackParser {

    /// Best-effort parse. Always returns; check `.chapters.isEmpty`
    /// at the call site to know if it actually got something.
    static func parse(url: URL, bookId: String) -> EbookFulltext {
        // 1. Find the OPF.
        guard let containerXML = ZipReader.extract(member: "META-INF/container.xml", from: url),
              let opfPath = EpubMetadataReader.parseOPFPath(in: containerXML),
              let opfData = ZipReader.extract(member: opfPath, from: url) else {
            return EbookFulltext(jobId: bookId, bookTitle: nil, bookAuthor: nil, chapters: [])
        }

        // 2. Pull manifest + spine + metadata from the OPF.
        let opfInfo = parseOPFForSpine(data: opfData)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // 3. Resolve each spine idref to its href and extract.
        var chapters: [EbookFulltext.Chapter] = []
        var index = 1
        for idref in opfInfo.spineOrder {
            guard let href = opfInfo.manifest[idref] else { continue }
            let chapterPath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            guard let htmlData = ZipReader.extract(member: chapterPath, from: url),
                  let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) else {
                continue
            }
            let text = stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name: String? = extractTitle(from: html) ?? "Chapter \(index)"
            chapters.append(EbookFulltext.Chapter(
                index: index,
                name: name,
                text: text,
                html: html,
                css: nil,
                charCount: text.count,
                segments: nil
            ))
            index += 1
        }

        return EbookFulltext(
            jobId: bookId,
            bookTitle: opfInfo.title,
            bookAuthor: opfInfo.author,
            chapters: chapters
        )
    }

    // MARK: - OPF spine extraction

    fileprivate struct OPFInfo {
        var title: String?
        var author: String?
        var manifest: [String: String] = [:]  // idref → href
        var spineOrder: [String] = []          // idrefs in reading order
    }

    fileprivate static func parseOPFForSpine(data: Data) -> OPFInfo {
        let delegate = SpineDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.info
    }

    // MARK: - HTML stripping

    /// Strip HTML tags + decode common entities. Preserves paragraph
    /// breaks (block elements → newline). Not a full sanitizer; we
    /// just want readable plain text for TTS / fallback display.
    fileprivate static func stripHTML(_ html: String) -> String {
        var output = ""
        var inTag = false
        var inScript = false
        var inStyle = false
        var tagBuffer = ""

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
                    if !output.hasSuffix("\n") { output.append("\n") }
                }
                tagBuffer = ""
            } else if inTag {
                tagBuffer.append(ch)
            } else if !inScript && !inStyle {
                output.append(ch)
            }
        }

        return decodeEntities(output)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    /// Decode the handful of HTML entities that actually appear in
    /// EPUBs. Full XML entity table is overkill — we cover the ones
    /// that matter for readability.
    fileprivate static func decodeEntities(_ s: String) -> String {
        var result = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"),
            ("&ldquo;", "“"), ("&rdquo;", "”"),
            ("&lsquo;", "‘"), ("&rsquo;", "’"),
            ("&hellip;", "…"),
        ]
        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities &#nnn; — defer; the named map covers ~95%.
        return result
    }

    /// Pull the chapter name from `<title>` or the first `<h1..h6>`.
    /// Returns nil if neither is present.
    fileprivate static func extractTitle(from html: String) -> String? {
        if let range = html.range(of: #"<title>([^<]+)</title>"#, options: .regularExpression) {
            let raw = String(html[range])
            if let openEnd = raw.range(of: ">"),
               let closeStart = raw.range(of: "</title>", options: .backwards) {
                let inner = raw[openEnd.upperBound..<closeStart.lowerBound]
                let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return decodeEntities(trimmed) }
            }
        }
        if let hRange = html.range(of: #"<h[1-6][^>]*>([^<]+)</h[1-6]>"#, options: .regularExpression) {
            let raw = String(html[hRange])
            if let openEnd = raw.range(of: ">"),
               let closeStart = raw.range(of: "</", options: .backwards) {
                let inner = raw[openEnd.upperBound..<closeStart.lowerBound]
                let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return decodeEntities(trimmed) }
            }
        }
        return nil
    }
}

// MARK: - Spine XML delegate

private final class SpineDelegate: NSObject, XMLParserDelegate {
    var info = EpubFallbackParser.OPFInfo()
    private var currentTag: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.lowercased()
        currentTag = tag
        buffer = ""
        if tag == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"] {
            info.manifest[id] = href
        }
        if tag == "itemref", let idref = attributeDict["idref"] {
            info.spineOrder.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "dc:title", "title":
            if info.title == nil, !trimmed.isEmpty { info.title = trimmed }
        case "dc:creator", "creator":
            if info.author == nil, !trimmed.isEmpty { info.author = trimmed }
        default: break
        }
        buffer = ""
        currentTag = nil
    }
}
