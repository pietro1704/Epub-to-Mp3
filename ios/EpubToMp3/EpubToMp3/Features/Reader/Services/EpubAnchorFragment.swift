import Foundation

/// Selects an EPUB element without treating nested closing tags as its boundary.
/// Malformed or ambiguous documents fail closed; no external entities are read.
enum EpubAnchorFragment {
    static func html(identifier: String, in html: String) -> String? {
        guard !identifier.isEmpty, html.utf8.count <= 2 * 1024 * 1024 else { return nil }
        var source = html.replacingOccurrences(of: #"(?is)<\?xml.*?\?>|<!DOCTYPE[^>]*>|<script\b[^>]*>.*?</script\s*>"#,
            with: "", options: .regularExpression)
        let entities = ["nbsp": "&#160;", "mdash": "&#8212;", "ndash": "&#8211;", "hellip": "&#8230;",
                        "lsquo": "&#8216;", "rsquo": "&#8217;", "ldquo": "&#8220;", "rdquo": "&#8221;"]
        for (name, value) in entities { source = source.replacingOccurrences(of: "&\(name);", with: value) }
        source = source.replacingOccurrences(of: #"(?i)<(br|hr|img|meta|link|input|wbr)\b([^>]*?)(?<!/)>"#,
            with: "<$1$2/>", options: .regularExpression)
        let capture = AnchorTree()
        let parser = XMLParser(data: Data("<reader-root>\(source)</reader-root>".utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = capture
        guard parser.parse() else { return nil }
        let matches = capture.root?.matches(identifier) ?? []
        guard matches.count == 1, let target = matches.first else { return nil }
        if target.name == "a", let parent = target.parent,
           !["reader-root", "html", "body"].contains(parent.name),
           !parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return parent.html }
        if !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return target.html }
        // Empty named anchors locate their surrounding block or next readable sibling.
        guard let parent = target.parent else { return nil }
        if !["reader-root", "html", "body"].contains(parent.name), !parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parent.html
        }
        guard let index = parent.children.firstIndex(where: { $0 === target }) else { return nil }
        return parent.children.dropFirst(index + 1).first {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.html
    }

    private final class Node {
        let name: String
        let attributes: [String: String]
        weak var parent: Node?
        var contents: [Content] = []
        enum Content { case text(String), element(Node) }
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
        var children: [Node] { contents.compactMap { if case .element(let node) = $0 { return node }; return nil } }
        var text: String { contents.map { switch $0 { case .text(let value): return value; case .element(let node): return node.text } }.joined() }
        var html: String {
            let attributes = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined()
            let body = contents.map { switch $0 { case .text(let value): return Self.escape(value); case .element(let node): return node.html } }.joined()
            return "<\(name)\(attributes)>\(body)</\(name)>"
        }
        func matches(_ identifier: String) -> [Node] {
            let own = attributes["id"] == identifier || attributes["xml:id"] == identifier
                || (name == "a" && attributes["name"] == identifier)
            return (own ? [self] : []) + children.flatMap { $0.matches(identifier) }
        }
        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
    }

    private final class AnchorTree: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard stack.count < 128 else { parser.abortParsing(); return }
            let node = Node(name: elementName, attributes: attributeDict)
            node.parent = stack.last
            if let parent = stack.last { parent.contents.append(.element(node)) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.contents.append(.text(string)) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}
