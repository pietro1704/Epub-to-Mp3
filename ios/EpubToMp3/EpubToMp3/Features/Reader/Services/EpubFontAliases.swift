import Foundation

/// Bridges publisher CSS aliases to fonts already registered for this book.
/// Unavailable, remote or unsupported faces keep their declared fallback list.
enum EpubFontAliases {
    static func families(css: String, resolve: (String) -> String?) -> [String: String] {
        let cleaned = css.replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: "", options: .regularExpression)
        let source = cleaned as NSString
        var aliases: [String: String] = [:]
        for face in matches("(?is)@font-face\\s*\\{([^{}]*)\\}", in: cleaned) {
            let declarations = source.substring(with: face.range(at: 1))
            guard let family = matches("(?i)font-family\\s*:\\s*([^;]+)", in: declarations).first else { continue }
            let alias = normalized((declarations as NSString).substring(with: family.range(at: 1)))
            guard !alias.isEmpty else { continue }
            for url in matches("(?i)url\\(\\s*(['\"]?)([^)'\"]+)\\1\\s*\\)", in: declarations) {
                let resource = (declarations as NSString).substring(with: url.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard URLComponents(string: resource)?.scheme == nil, !resource.hasPrefix("//"),
                      let resolved = resolve(resource) else { continue }
                aliases[alias] = resolved
                break
            }
        }
        return aliases
    }

    static func rewrite(_ css: String, families: [String: String]) -> String {
        guard !families.isEmpty else { return css }
        var rewritten = css
        for declaration in matches("(?i)font-family\\s*:\\s*([^;}]+)", in: css).reversed() {
            let range = declaration.range(at: 1)
            let value = (css as NSString).substring(with: range)
            let priority = value.range(of: "(?i)\\s*!important\\s*$", options: .regularExpression)
            let list = priority.map { String(value[..<$0.lowerBound]) } ?? value
            let choices = matches("'[^']*'|\"[^\"]*\"|[^,]+", in: list).map {
                (list as NSString).substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let replacements = choices.map { choice -> String in
                guard let family = families[normalized(choice)] else { return choice }
                return "\"" + family.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            if replacements != choices, let swiftRange = Range(range, in: rewritten) {
                rewritten.replaceSubrange(swiftRange, with: replacements.joined(separator: ", ") + (priority == nil ? "" : " !important"))
            }
        }
        return rewritten
    }

    static func rewriteInlineStyles(_ html: String, families: [String: String]) -> String {
        guard !families.isEmpty else { return html }
        var rewritten = html
        for tag in matches("(?is)<[^>]+>", in: html).reversed() {
            guard let range = Range(tag.range, in: rewritten) else { continue }
            let source = (html as NSString).substring(with: tag.range)
            rewritten.replaceSubrange(range, with: rewriteAttributes(source, families: families))
        }
        return rewritten
    }

    private static func rewriteAttributes(_ html: String, families: [String: String]) -> String {
        var rewritten = html
        for style in matches("(?is)\\bstyle\\s*=\\s*(['\"])(.*?)\\1", in: html).reversed() {
            let range = style.range(at: 2)
            let value = (html as NSString).substring(with: range)
            guard let swiftRange = Range(range, in: rewritten) else { continue }
            let quote = (html as NSString).substring(with: style.range(at: 1))
            let resolved = rewrite(value, families: families).replacingOccurrences(of: quote,
                with: quote == "\"" ? "&quot;" : "&#39;")
            rewritten.replaceSubrange(swiftRange, with: resolved)
        }
        return rewritten
    }

    private static func normalized(_ family: String) -> String {
        family.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")).lowercased()
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: source,
            range: NSRange(source.startIndex..., in: source))) ?? []
    }
}
