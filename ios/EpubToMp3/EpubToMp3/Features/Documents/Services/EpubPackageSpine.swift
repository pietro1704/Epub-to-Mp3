import Foundation

enum EpubPackageSpine {
    // MARK: - OPF spine extraction

    struct Package {
        var title: String?
        var author: String?
        var manifest: [String: String] = [:]  // idref → href
        var cssHrefs: [String] = []
        var navigationHref: String?
        var ncxID: String?
        var spineTocID: String?
        var spineOrder: [String] = []          // idrefs in reading order
    }

    static func parse(data: Data) -> Package {
        let delegate = EpubPackageSpineDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.info
    }

}

// MARK: - Spine XML delegate

private final class EpubPackageSpineDelegate: NSObject, XMLParserDelegate {
    var info = EpubPackageSpine.Package()
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
            info.manifest[id] = href.removingPercentEncoding ?? href
            if attributeDict["properties"]?.split(whereSeparator: \.isWhitespace).contains("nav") == true {
                info.navigationHref = href
            }
            if attributeDict["media-type"]?.lowercased() == "application/x-dtbncx+xml" { info.ncxID = id }
            if attributeDict["media-type"]?.lowercased() == "text/css" || href.lowercased().hasSuffix(".css") {
                info.cssHrefs.append(href)
            }
        }
        if tag == "spine" { info.spineTocID = attributeDict["toc"] }
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
