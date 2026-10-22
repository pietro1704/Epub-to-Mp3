import Foundation

enum EpubFallbackResources {
    static func images(
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
            let path = EpubArchivePath.normalize(chapterDirectory.isEmpty ? cleanHref : "\(chapterDirectory)/\(cleanHref)")
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

    /// Extracts only explicitly-linked footnote bodies, with strict per-file
    /// bounds. This keeps a fallback payload navigable without duplicating
    /// the canonical parser's general TOC and note extraction logic.
    static func footnotes(
        in html: String,
        chapterPath: String,
        archiveURL: URL
    ) -> [EbookFulltext.Footnote] {
        let anchorPattern = try? NSRegularExpression(
            pattern: #"(?is)<a\b[^>]*\bhref\s*=\s*([\"'])([^\"']+)\1[^>]*>(.*?)</a\s*>"#
        )
        let range = NSRange(html.startIndex..., in: html)
        let chapterDirectory = (chapterPath as NSString).deletingLastPathComponent
        var notes: [EbookFulltext.Footnote] = []
        var seen = Set<String>()
        for match in anchorPattern?.matches(in: html, range: range) ?? [] {
            guard let hrefRange = Range(match.range(at: 2), in: html),
                  let labelRange = Range(match.range(at: 3), in: html) else { continue }
            let href = String(html[hrefRange])
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let targetPath = String(parts[0])
            let fragment = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            let marker = "\(targetPath)#\(fragment)".lowercased()
            guard marker.contains("foot") || marker.contains("note") else { continue }
            let path: String
            if targetPath.isEmpty {
                path = chapterPath
            } else {
                path = EpubArchivePath.normalize(
                    chapterDirectory.isEmpty ? targetPath : "\(chapterDirectory)/\(targetPath)"
                )
            }
            guard let data = ZipReader.extract(member: path, from: archiveURL),
                  !data.isEmpty, data.count <= 2 * 1024 * 1024,
                  let targetHTML = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1),
                  let body = elementBody(withID: fragment, in: targetHTML) else { continue }
            let text = EpubFallbackText.stripHTML(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let number = EpubFallbackText.stripHTML(String(html[labelRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(number)|\(text)"
            guard seen.insert(key).inserted else { continue }
            notes.append(.init(number: number.isEmpty ? nil : number, text: text))
        }
        return notes
    }

    private static func elementBody(withID identifier: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let pattern = #"(?is)<([a-z][\w:-]*)\b[^>]*(?:xml:)?id\s*=\s*([\"'])"#
            + escaped
            + #"\2[^>]*>(.*?)</\1\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 3), in: html) else { return nil }
        return String(html[range])
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

}
