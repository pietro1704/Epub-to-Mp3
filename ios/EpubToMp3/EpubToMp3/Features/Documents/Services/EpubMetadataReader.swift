import Foundation

/// Best-effort EPUB metadata reader. EPUB is a ZIP container with an
/// `OPF` manifest at a path advertised by `META-INF/container.xml`.
///
/// Implementation: in-process `ZipReader` (Compression.framework). We
/// used to shell out to `/usr/bin/unzip -p` on macOS, but App Sandbox
/// strips the parent's security-scoped access from any subprocess —
/// the user picks an EPUB from `~/Books/`, the parent gets read access,
/// `Process` spawns `unzip`, the subprocess can't read the file, and
/// the import fails with "couldn't be opened". A pure-Swift reader
/// also gives us iOS support without a third-party dependency.
enum EpubMetadataReader {

    struct Payload {
        var title: String?
        var author: String?
        var language: String?
        var cover: Data?

        init(title: String? = nil, author: String? = nil, language: String? = nil, cover: Data? = nil) {
            self.title = title
            self.author = author
            self.language = language
            self.cover = cover
        }
    }

    static func readMetadata(from url: URL) throws -> Payload {
        // 1. Extract container.xml to discover the OPF path.
        guard let containerXML = ZipReader.extract(member: "META-INF/container.xml", from: url),
              let opfPath = parseOPFPath(in: containerXML) else {
            return Payload()
        }
        // 2. Extract the OPF manifest itself.
        guard let opfData = ZipReader.extract(member: opfPath, from: url) else {
            return Payload()
        }
        let parsed = parseOPF(data: opfData)
        var payload = Payload(title: parsed.title, author: parsed.author, language: parsed.language)

        // 3. Resolve the cover image (if the OPF advertised one) and
        //    extract that ZIP member as well. Cover paths are relative
        //    to the OPF directory.
        if let coverHref = parsed.coverHref {
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let coverPath = opfDir.isEmpty ? coverHref : "\(opfDir)/\(coverHref)"
            payload.cover = ZipReader.extract(member: coverPath, from: url)
        }
        return payload
    }

    // MARK: - XML parsing

    /// Pull `<rootfile full-path="...">` from `META-INF/container.xml`.
    static func parseOPFPath(in data: Data) -> String? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        // Lazy regex (no XMLParser dance for this single attribute).
        guard let range = str.range(of: #"full-path\s*=\s*"([^"]+)""#,
                                    options: .regularExpression) else { return nil }
        let raw = String(str[range])
        // Strip the attribute name + quotes.
        if let quoteStart = raw.firstIndex(of: "\""),
           let quoteEnd = raw.lastIndex(of: "\""),
           quoteStart < quoteEnd {
            return String(raw[raw.index(after: quoteStart)..<quoteEnd])
        }
        return nil
    }

    struct OPFMetadata {
        var title: String?
        var author: String?
        var language: String?
        var coverHref: String?
    }

    /// Tiny OPF parser — delegates to `XMLParser` because libxml2 is
    /// already linked. We only care about three fields, so we keep
    /// state machines minimal.
    static func parseOPF(data: Data) -> OPFMetadata {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        _ = parser.parse()
        return OPFMetadata(
            title: delegate.title,
            author: delegate.author,
            language: delegate.language,
            coverHref: delegate.coverHref
        )
    }
}

/// Internal XML delegate. Standalone so it stays out of the public API.
private final class OPFDelegate: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var language: String?
    var coverHref: String?

    private var coverItemId: String?
    private var manifestItems: [String: String] = [:]   // id → href
    private var currentTag: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentTag = elementName.lowercased()
        buffer = ""
        // Cover <meta name="cover" content="<id>"/> form.
        if elementName.lowercased() == "meta",
           let name = attributeDict["name"]?.lowercased(),
           name == "cover",
           let content = attributeDict["content"] {
            coverItemId = content
        }
        // Manifest items.
        if elementName.lowercased() == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"] {
            manifestItems[id] = href
            let properties = attributeDict["properties"]?.lowercased() ?? ""
            if properties.contains("cover-image") {
                coverItemId = id
            }
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
        case "dc:language", "language":
            if language == nil, !trimmed.isEmpty { language = trimmed }
        default: break
        }
        buffer = ""
        currentTag = nil
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if let id = coverItemId, let href = manifestItems[id] {
            coverHref = href
        }
    }
}
