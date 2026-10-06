import Foundation

/// Maps an EPUB hyperlink to a reader action without exposing archive-local
/// paths to UIKit's default URL opener.
enum ReaderLinkDestination: Equatable {
    case chapter(Int)
    case footnote(EbookFulltext.Footnote)
    case external(URL)
    case unresolved
}

enum ReaderLinkResolver {
    static func destination(
        for url: URL,
        linkText: String,
        currentChapter: EbookFulltext.Chapter,
        chapters: [EbookFulltext.Chapter]
    ) -> ReaderLinkDestination {
        if let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme) {
            return .external(url)
        }

        guard let target = rawTarget(from: url), !target.isEmpty else {
            return .unresolved
        }
        let split = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(split.first ?? "")
        let fragment = split.count > 1 ? String(split[1]) : ""

        if let footnote = footnote(
            linkText: linkText,
            targetPath: rawPath,
            fragment: fragment,
            footnotes: currentChapter.footnotes ?? []
        ) {
            return .footnote(footnote)
        }

        if let index = chapterIndex(
            for: rawPath,
            linkText: linkText,
            currentSourcePath: currentChapter.sourcePath,
            chapters: chapters
        ) {
            return .chapter(index)
        }

        return .unresolved
    }

    private static func rawTarget(from url: URL) -> String? {
        if url.scheme?.lowercased() == "epub-link" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "target" })?
                .value
        }
        return url.relativeString.removingPercentEncoding ?? url.relativeString
    }

    private static func chapterIndex(
        for rawPath: String,
        linkText: String,
        currentSourcePath: String?,
        chapters: [EbookFulltext.Chapter]
    ) -> Int? {
        let resolved = resolvePath(rawPath, relativeTo: currentSourcePath)
        if !resolved.isEmpty,
           let index = chapters.firstIndex(where: {
               let source = normalisedPath($0.sourcePath ?? "")
               return source == resolved || source.hasSuffix("/" + resolved)
           }) {
            return index
        }

        let label = normalisedTitle(linkText)
        guard !label.isEmpty else { return nil }
        return chapters.firstIndex { chapter in
            let title = normalisedTitle(chapter.displayTitle)
            return title == label || title.contains(label) || label.contains(title)
        }
    }

    private static func footnote(
        linkText: String,
        targetPath: String,
        fragment: String,
        footnotes: [EbookFulltext.Footnote]
    ) -> EbookFulltext.Footnote? {
        guard !footnotes.isEmpty else { return nil }
        let marker = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = footnotes.first(where: { $0.number == marker }) {
            return exact
        }

        let target = "\(targetPath)#\(fragment)".lowercased()
        guard target.contains("foot") || target.contains("note") else {
            return nil
        }
        let digits = target.reversed().prefix { $0.isNumber }.reversed()
        if !digits.isEmpty,
           let numbered = footnotes.first(where: { $0.number == String(digits) }) {
            return numbered
        }
        return footnotes.count == 1 ? footnotes[0] : nil
    }

    private static func resolvePath(_ rawPath: String, relativeTo currentSourcePath: String?) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard !decoded.isEmpty else { return normalisedPath(currentSourcePath ?? "") }
        if decoded.hasPrefix("/") { return normalisedPath(decoded) }
        let base = currentSourcePath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        return normalisedPath(base.isEmpty ? decoded : "\(base)/\(decoded)")
    }

    private static func normalisedPath(_ path: String) -> String {
        var pieces: [Substring] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch part {
            case ".", "": continue
            case "..": if !pieces.isEmpty { pieces.removeLast() }
            default: pieces.append(part)
            }
        }
        return pieces.joined(separator: "/").lowercased()
    }

    private static func normalisedTitle(_ value: String) -> String {
        let stem = value
            .replacingOccurrences(of: #"(?i)\.(xhtml|html|htm)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        return stem.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
