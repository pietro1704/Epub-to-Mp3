import Foundation

/// Minimal pure-Swift EPUB → `EbookFulltext` safety net. Used ONLY when
/// the in-process Python pipeline (`PythonBridge.parseEpub`) — the sole
/// source of truth for book structure — fails or times out.
///
/// Python (`python_app/src/ebook_reader.py`) owns every structural
/// feature: TOC hierarchy, footnote extraction, oversized-chapter
/// detection, duplicate-chapter removal, per-chapter language tagging,
/// title resolution. This parser deliberately does NOT re-implement any
/// of that — it exists to put *readable plain text* on screen when Python
/// is unavailable, nothing more. Duplicating that logic here means two
/// implementations drifting apart, and it's exactly what caused a
/// multi-GB memory crash (`stripHTML` running unbounded regex over a
/// whole book after a spine misparse) that a plain-text-only parser has
/// no surface for.
///
/// Strategy: walk the OPF `<spine>` in order and preserve the source XHTML.
/// Plain text remains available for search and speech fallback, while the
/// native reader renders the original markup.
///
/// Never throws: returns an empty `EbookFulltext` (zero chapters) if the
/// EPUB is truly unreadable. Callers decide whether to surface that as an
/// error.
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

        // 2. Pull manifest + spine + title/author from the OPF.
        let opfInfo = parseOPFForSpine(data: opfData)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // 3. Resolve each spine idref to its href and preserve source markup.
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
            let title = firstHeading(in: html) ?? "Chapter \(index)"
            let css = opfInfo.cssHrefs.compactMap { href -> String? in
                let path = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
                guard let data = ZipReader.extract(member: path, from: url) else { return nil }
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }.joined(separator: "\n")
            let resources = imageResources(in: html, chapterPath: chapterPath, archiveURL: url)
            chapters.append(EbookFulltext.Chapter(
                index: index,
                name: title,
                text: text,
                html: html,
                css: css.isEmpty ? nil : css,
                charCount: text.count,
                segments: nil,
                resources: resources.isEmpty ? nil : resources
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

    private static func firstHeading(in html: String) -> String? {
        guard let match = html.range(of: #"(?is)<h[1-6][^>]*>.*?</h[1-6]>"#, options: .regularExpression) else {
            return nil
        }
        let text = stripHTML(String(html[match])).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func imageResources(
        in html: String,
        chapterPath: String,
        archiveURL: URL
    ) -> [EbookFulltext.Chapter.Resource] {
        let pattern = try? NSRegularExpression(
            pattern: #"(?i)<img\b[^>]*\bsrc\s*=\s*([\"'])([^\"']+)\1[^>]*>"#
        )
        let range = NSRange(html.startIndex..., in: html)
        let chapterDirectory = (chapterPath as NSString).deletingLastPathComponent
        return (pattern?.matches(in: html, range: range) ?? []).compactMap { match in
            guard let hrefRange = Range(match.range(at: 2), in: html) else { return nil }
            let href = String(html[hrefRange])
            guard !href.lowercased().hasPrefix("data:") else { return nil }
            let cleanHref = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
            let path = normalizeZipPath(chapterDirectory.isEmpty ? cleanHref : "\(chapterDirectory)/\(cleanHref)")
            guard let data = ZipReader.extract(member: path, from: archiveURL),
                  !data.isEmpty, data.count <= 12 * 1024 * 1024 else { return nil }
            let mediaType = mimeType(for: path)
            return EbookFulltext.Chapter.Resource(
                href: href,
                mediaType: mediaType,
                dataBase64: data.base64EncodedString()
            )
        }
    }

    private static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private static func normalizeZipPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    // MARK: - OPF spine extraction

    fileprivate struct OPFInfo {
        var title: String?
        var author: String?
        var manifest: [String: String] = [:]  // idref → href
        var cssHrefs: [String] = []
        var spineOrder: [String] = []          // idrefs in reading order
    }

    fileprivate static func parseOPFForSpine(data: Data) -> OPFInfo {
        let delegate = SpineDelegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        _ = parser.parse()
        return delegate.info
    }

    // MARK: - HTML stripping

    /// Strip HTML tags + decode common entities. Preserves paragraph
    /// breaks (block elements → newline). Not a full sanitizer; we
    /// just want readable plain text for TTS / fallback display.
    fileprivate static func stripHTML(_ html: String) -> String {
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
            if attributeDict["media-type"]?.lowercased() == "text/css" || href.lowercased().hasSuffix(".css") {
                info.cssHrefs.append(href)
            }
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
