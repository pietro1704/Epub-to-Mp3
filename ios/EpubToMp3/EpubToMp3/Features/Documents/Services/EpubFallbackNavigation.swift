import Foundation

enum EpubFallbackNavigation {
    final class Node {
        var title = ""
        var href: String?
        var path: String?
        var children: [Node] = []
    }

    static func nodes(info: EpubPackageSpine.Package, opfDirectory: String, archiveURL: URL) -> [Node] {
        let ncx = (info.spineTocID ?? info.ncxID).flatMap { info.manifest[$0] }
        for (href, isNav) in [(info.navigationHref, true), (ncx, false)] {
            guard let href,
                  let path = navigationPath(href, relativeTo: opfDirectory),
                  let data = ZipReader.extract(member: path, from: archiveURL),
                  data.count <= 2 * 1024 * 1024 else { continue }
            let delegate = NavigationDelegate(isNav: isNav)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), !delegate.roots.isEmpty else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            func resolve(_ nodes: [Node]) {
                for node in nodes {
                    node.title = node.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    node.path = node.href.flatMap { navigationPath($0, relativeTo: directory) }
                    resolve(node.children)
                }
            }
            resolve(delegate.roots)
            return delegate.roots
        }
        return []
    }

    /// Fragment anchors belong to their containing spine document; they never
    /// become chapter ordinals. External links cannot resolve to local chapters.
    private static func navigationPath(_ href: String, relativeTo directory: String) -> String? {
        guard !href.hasPrefix("/"), !href.contains(":"), !href.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        guard let file = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first,
              !file.isEmpty else { return nil }
        let decoded = String(file).removingPercentEncoding ?? String(file)
        return EpubArchivePath.normalize(directory.isEmpty ? decoded : "\(directory)/\(decoded)")
    }

    private final class NavigationDelegate: NSObject, XMLParserDelegate {
        let isNav: Bool
        var roots: [Node] = []
        private var stack: [Node] = []
        private var elementDepth = 0
        private var tocDepth: Int?
        private var labelDepth: Int?
        private var nodes = 0

        init(isNav: Bool) { self.isNav = isNav }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            elementDepth += 1
            let tag = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName
            if isNav, tag == "nav", tocDepth == nil {
                let type = attributes["epub:type"] ?? attributes["type"] ?? ""
                if type.split(whereSeparator: \.isWhitespace).contains("toc") || attributes["role"] == "doc-toc" {
                    tocDepth = elementDepth
                }
            }
            guard !isNav || tocDepth != nil else { return }
            if tag == (isNav ? "li" : "navpoint") {
                nodes += 1
                guard nodes <= 10_000, stack.count < 64 else { parser.abortParsing(); return }
                let node = Node()
                if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
                stack.append(node)
            }
            guard let node = stack.last else { return }
            if isNav && (tag == "a" || tag == "span") && labelDepth == nil {
                node.href = attributes["href"]
                labelDepth = elementDepth
            } else if !isNav && tag == "content" { node.href = attributes["src"] }
            else if !isNav && tag == "text" { labelDepth = elementDepth }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard labelDepth != nil, let node = stack.last else { return }
            node.title.append(string)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let tag = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName
            if elementDepth == labelDepth { labelDepth = nil }
            if (!isNav || tocDepth != nil), tag == (isNav ? "li" : "navpoint"), !stack.isEmpty {
                stack.removeLast()
            }
            if elementDepth == tocDepth { tocDepth = nil }
            elementDepth -= 1
        }
    }

}
