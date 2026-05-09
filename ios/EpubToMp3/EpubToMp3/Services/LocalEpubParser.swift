import Foundation

/// Parses an EPUB into the same `EbookFulltext` shape the backend
/// produces, but **entirely on-device**. The reader can render the
/// book the moment the user picks it — no round-trip to the
/// conversion server, no waiting on `/api/jobs/{id}/fulltext`.
///
/// Scope:
///   - Spine items in order → one `Chapter` each.
///   - Text extracted by stripping HTML tags (rough but works for
///     ePub3 reflowable text). Markup-heavy fixed-layout EPUBs may
///     come back with empty chapters; the backend parser is the
///     authoritative path for those cases.
///   - Title / author / cover via the existing `EpubMetadataReader`.
enum LocalEpubParser {

    /// Build a fulltext payload from an on-disk EPUB. Returns nil if
    /// the archive is malformed (missing container.xml or OPF).
    /// `bookId` is propagated as `EbookFulltext.jobId` so downstream
    /// caches keyed on `jobId` (FulltextStore's disk cache, etc.) line
    /// up with what the backend would have returned.
    static func parse(url: URL, bookId: String) -> EbookFulltext? {
        guard let containerXML = ZipReader.extract(member: "META-INF/container.xml", from: url),
              let opfPath = EpubMetadataReader.parseOPFPath(in: containerXML),
              let opfData = ZipReader.extract(member: opfPath, from: url) else {
            return nil
        }

        let opf = parseOPF(data: opfData)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        // Walk the spine in order; each idref points at a manifest
        // item whose href is the XHTML chapter file.
        var chapters: [EbookFulltext.Chapter] = []
        var index = 1
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let memberPath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            guard let xhtml = ZipReader.extract(member: memberPath, from: url),
                  let html = String(data: xhtml, encoding: .utf8) else {
                continue
            }
            let title = chapterTitle(in: html) ?? "Chapter \(index)"
            let text = stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            chapters.append(EbookFulltext.Chapter(
                index: index,
                name: title,
                text: text,
                html: nil,
                css: nil,
                charCount: text.count,
                segments: nil
            ))
            index += 1
        }

        guard !chapters.isEmpty else { return nil }

        return EbookFulltext(
            jobId: bookId,
            bookTitle: opf.title,
            bookAuthor: opf.author,
            chapters: chapters
        )
    }

    // MARK: - OPF parsing

    private struct OPFData {
        var title: String?
        var author: String?
        var manifest: [String: String]   // id → href
        var spine: [String]               // idref order
    }

    private static func parseOPF(data: Data) -> OPFData {
        let delegate = SpineDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return OPFData(
            title: delegate.title,
            author: delegate.author,
            manifest: delegate.manifest,
            spine: delegate.spine
        )
    }

    // MARK: - HTML helpers

    /// Pull the first `<h1>` / `<h2>` / `<title>` we see — that's the
    /// closest thing to a chapter title an EPUB's XHTML carries.
    private static func chapterTitle(in html: String) -> String? {
        for tag in ["h1", "h2", "h3", "title"] {
            if let m = html.range(of: "<\(tag)[^>]*>(.*?)</\(tag)>",
                                  options: [.regularExpression, .caseInsensitive]) {
                let raw = String(html[m])
                let inner = stripHTML(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        return nil
    }

    /// Crude HTML → plain text. Strips tags, decodes the most common
    /// entities, collapses runs of whitespace. Good enough for the
    /// reader pane; the backend remains authoritative for TTS-quality
    /// extraction (footnotes, dialogue cues, etc.).
    static func stripHTML(_ html: String) -> String {
        var s = html
        // Drop script/style blocks entirely.
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Replace block-level closing tags with newlines so
        // paragraphs don't fuse together.
        let blockClose = ["</p>", "</div>", "</li>", "</h1>", "</h2>",
                          "</h3>", "</h4>", "</h5>", "</h6>", "<br>", "<br/>", "<br />"]
        for tag in blockClose {
            s = s.replacingOccurrences(of: tag, with: "\n",
                                       options: .caseInsensitive)
        }
        // Strip the rest of the tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "",
                                   options: .regularExpression)
        // Decode the entities that show up in 99% of EPUBs.
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&ldquo;", "“"), ("&rdquo;", "”"),
            ("&lsquo;", "‘"), ("&rsquo;", "’"),
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // Numeric entities (best effort).
        s = s.replacingOccurrences(
            of: "&#(\\d+);",
            with: "",
            options: [.regularExpression]
        )
        // Collapse whitespace (preserve paragraph breaks).
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ",
                                   options: [.regularExpression])
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n",
                                   options: [.regularExpression])
        return s
    }
}

private final class SpineDelegate: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var manifest: [String: String] = [:]
    var spine: [String] = []

    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        let name = elementName.lowercased()
        if name == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"] {
            manifest[id] = href
        } else if name == "itemref",
                  let idref = attributeDict["idref"] {
            // Honour `linear="no"` only when explicit; default is yes.
            if attributeDict["linear"]?.lowercased() == "no" { return }
            spine.append(idref)
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
            if title == nil, !trimmed.isEmpty { title = trimmed }
        case "dc:creator", "creator":
            if author == nil, !trimmed.isEmpty { author = trimmed }
        default: break
        }
        buffer = ""
    }
}
