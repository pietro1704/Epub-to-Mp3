import Foundation

/// Local Apple reader projection of an EPUB. Preserve spine document identity
/// and source markup, while using the declared EPUB navigation for labels and
/// hierarchy. Rust remains responsible for conversion and synthesis structure.
/// This reader projection does not split/reorder chapters or import publisher CSS.
/// Unreadable input yields an empty payload; missing navigation keeps a flat list.
enum EpubFallbackParser {

    /// Keep archive IO and extraction independent of the caller's executor.
    static func parseAsync(url: URL, bookId: String,
                           parser: @escaping @Sendable (URL, String) -> EbookFulltext = {
                               parse(url: $0, bookId: $1)
                           }) async -> EbookFulltext {
        await Task.detached(priority: .userInitiated) {
            parser(url, bookId)
        }.value
    }

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
        let opfInfo = EpubPackageSpine.parse(data: opfData)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let navigation = EpubFallbackNavigation.nodes(info: opfInfo, opfDirectory: opfDir, archiveURL: url)
        var navigationTitles: [String: String] = [:]
        func collectTitles(_ nodes: [EpubFallbackNavigation.Node]) {
            for node in nodes {
                if let path = node.path, navigationTitles[path] == nil, !node.title.isEmpty {
                    navigationTitles[path] = node.title
                }
                collectTitles(node.children)
            }
        }
        collectTitles(navigation)

        // 3. Resolve each spine idref to its href and preserve source markup.
        var chapters: [EbookFulltext.Chapter] = []
        var index = 1
        for idref in opfInfo.spineOrder {
            guard let href = opfInfo.manifest[idref] else { continue }
            let chapterPath = EpubArchivePath.normalize(opfDir.isEmpty ? href : "\(opfDir)/\(href)")
            guard let htmlData = ZipReader.extract(member: chapterPath, from: url),
                  let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) else {
                continue
            }
            let text = EpubFallbackText.stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let title = navigationTitles[chapterPath] ?? EpubFallbackText.firstHeading(in: html) ?? "Chapter \(index)"
            let resources = EpubFallbackResources.images(in: html, chapterPath: chapterPath, archiveURL: url)
            let footnotes = EpubFallbackResources.footnotes(in: html, chapterPath: chapterPath, archiveURL: url)
            chapters.append(EbookFulltext.Chapter(
                index: index,
                name: title,
                sourcePath: chapterPath,
                text: text,
                html: html,
                css: nil,
                charCount: text.count,
                segments: nil,
                resources: resources.isEmpty ? nil : resources,
                footnotes: footnotes.isEmpty ? nil : footnotes
            ))
            index += 1
        }

        var chapterIndices: [String: Int] = [:]
        for chapter in chapters {
            if let path = chapter.sourcePath, chapterIndices[path] == nil { chapterIndices[path] = chapter.index }
        }
        func entries(_ nodes: [EpubFallbackNavigation.Node], level: Int) -> [EbookFulltext.TocEntry] {
            nodes.map { node in
                .init(title: node.title, level: level, chapterIndex: node.path.flatMap { chapterIndices[$0] },
                      children: entries(node.children, level: level + 1))
            }
        }
        return EbookFulltext(
            jobId: bookId,
            bookTitle: opfInfo.title,
            bookAuthor: opfInfo.author,
            chapters: chapters,
            toc: navigation.isEmpty ? nil : entries(navigation, level: 1)
        )
    }

}
