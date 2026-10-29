import Foundation

/// Preserves publisher document context while assembling the native HTML import.
struct EpubSourceDocument {
    let body: String
    let bodyAttributes: String
    let htmlAttributes: String
    let css: String

    init(html: String, css: String?) {
        let source = html as NSString
        let styles = Self.matches("(?is)<style\\b[^>]*>(.*?)</style\\s*>", in: html)
            .map { source.substring(with: $0.range(at: 1)) }
        self.css = ([css ?? ""] + styles).filter { !$0.isEmpty }.joined(separator: "\n")
        htmlAttributes = Self.matches("(?is)<html\\b([^>]*)>", in: html).first
            .map { source.substring(with: $0.range(at: 1)) } ?? ""
        let openingBody = Self.matches("(?is)<body\\b([^>]*)>", in: html).first
        bodyAttributes = openingBody.map { source.substring(with: $0.range(at: 1)) } ?? ""
        let closingBody = Self.matches("(?is)</body\\s*>", in: html).last
        let content: String
        if let openingBody, let closingBody, NSMaxRange(openingBody.range) <= closingBody.range.location {
            content = source.substring(with: NSRange(location: NSMaxRange(openingBody.range),
                length: closingBody.range.location - NSMaxRange(openingBody.range)))
        } else { content = html }
        body = content.replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style\\s*>|<link\\b[^>]*>",
            with: "", options: .regularExpression)
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: source,
            range: NSRange(source.startIndex..., in: source))) ?? []
    }
}
