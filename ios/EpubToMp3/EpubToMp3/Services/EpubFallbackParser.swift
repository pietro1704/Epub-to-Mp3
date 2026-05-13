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

        // 3. Parse NCX/nav TOC for proper chapter names keyed by href.
        var tocNames: [String: String] = [:]
        if let tocRelPath = opfInfo.tocHref {
            let tocPath = opfDir.isEmpty ? tocRelPath : "\(opfDir)/\(tocRelPath)"
            if let tocData = ZipReader.extract(member: tocPath, from: url) {
                tocNames = parseNCXLabels(data: tocData)
            }
        }

        // 4. Resolve each spine idref to its href and extract.
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
            let tocName = tocNames[href] ?? tocNames[chapterPath]
            let name: String? = tocName ?? extractTitle(from: html) ?? "Chapter \(index)"
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
        var manifestMediaTypes: [String: String] = [:]  // idref → media-type
        var spineOrder: [String] = []          // idrefs in reading order
        var tocHref: String?                   // NCX or nav.xhtml path
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

    fileprivate static func extractTitle(from html: String) -> String? {
        // 1. Prefer <h1..h6> — headings carry real chapter names.
        //    Match headings with nested inline elements (span, em, b, etc.)
        //    by stripping inner tags.
        if let regex = try? NSRegularExpression(pattern: "<h[1-6][^>]*>(.*?)</h[1-6]>",
                                                    options: .dotMatchesLineSeparators),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let innerRange = Range(match.range(at: 1), in: html) {
            let inner = String(html[innerRange])
            let stripped = inner.replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                                      options: .regularExpression)
            let trimmed = decodeEntities(stripped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // 2. Fall back to <title>, but only if it looks like a real name
        //    (not an opaque id like "c0", "section3", "ch-7a").
        if let range = html.range(of: #"<title>([^<]+)</title>"#, options: .regularExpression) {
            let raw = String(html[range])
            if let openEnd = raw.range(of: ">"),
               let closeStart = raw.range(of: "</title>", options: .backwards) {
                let inner = raw[openEnd.upperBound..<closeStart.lowerBound]
                let trimmed = decodeEntities(String(inner))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, looksLikeRealTitle(trimmed) {
                    return trimmed
                }
            }
        }
        return nil
    }

    fileprivate static func parseNCXLabels(data: Data) -> [String: String] {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.labels
    }

    private static func looksLikeRealTitle(_ s: String) -> Bool {
        if s.count < 3 { return false }
        if s.contains(" ") { return true }
        if s.first?.isUppercase == true { return true }
        return false
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
            if let mt = attributeDict["media-type"] { info.manifestMediaTypes[id] = mt }
            if attributeDict["properties"]?.contains("nav") == true {
                info.tocHref = href
            }
        }
        if tag == "itemref", let idref = attributeDict["idref"] {
            info.spineOrder.append(idref)
        }
        if tag == "spine", let toc = attributeDict["toc"] {
            if let href = info.manifest[toc] { info.tocHref = href }
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

// MARK: - NCX / nav.xhtml TOC delegate

private final class NCXDelegate: NSObject, XMLParserDelegate {
    var labels: [String: String] = [:]
    private var buffer = ""
    private var currentSrc: String?
    private var currentLabel: String?
    private var inNavLabel = false
    private var inText = false
    private var inNavPoint = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.lowercased()
        if tag == "navpoint" { inNavPoint = true; currentSrc = nil; currentLabel = nil }
        if tag == "navlabel" { inNavLabel = true }
        if inNavLabel && tag == "text" { inText = true; buffer = "" }
        if tag == "content", let src = attributeDict["src"] {
            currentSrc = src.components(separatedBy: "#").first
        }
        // EPUB3 nav.xhtml: <a href="ch1.xhtml">Chapter Name</a>
        if tag == "a", let href = attributeDict["href"] {
            currentSrc = href.components(separatedBy: "#").first
            inText = true; buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let tag = elementName.lowercased()
        if inText && (tag == "text" || tag == "a") {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { currentLabel = trimmed }
            inText = false
            buffer = ""
        }
        if tag == "navlabel" { inNavLabel = false }
        if tag == "navpoint" || tag == "li" {
            if let src = currentSrc, let label = currentLabel {
                labels[src] = label
            }
            if tag == "navpoint" { inNavPoint = false }
            currentSrc = nil
            currentLabel = nil
        }
    }
}
