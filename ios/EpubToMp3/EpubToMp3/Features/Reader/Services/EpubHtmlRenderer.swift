import Foundation
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

/// Renders a chapter's raw HTML body + per-chapter CSS into an
/// AttributedString suitable for UIKit/AppKit text views, then layers the
/// user's reader overrides on top.
///
/// The first pass uses Cocoa's `NSAttributedString(data:options:...)`
/// HTML importer (the same machinery `NSTextStorage` and Safari's
/// "View Source" snippet uses). That gives us EPUB-native bold, italic,
/// headings, blockquote, link colour, inline `<span style="color:…">`,
/// list bullets, etc. — for free.
///
/// The second pass walks the resulting `NSAttributedString` runs and
/// applies whichever overrides the user has opted into (font family,
/// size, foreground/background colour, bold-all, suppress-italic,
/// kerning). Overrides default to OFF so the EPUB's typography wins
/// until the user explicitly takes control.
///
/// ## Known limitations
///
/// - `NSAttributedString.html` importer is single-threaded under the
///   hood and **must run on the main thread**. We mark the API
///   `@MainActor` so callers can't accidentally spin it off a queue
///   and crash. ~50–200 ms per chapter is normal for a 30 K-char
///   payload; cache aggressively at the call site.
/// - `@font-face` rules embedded in EPUB CSS are NOT honoured by the
///   importer (it can't fetch the font file from the EPUB bundle).
///   Custom fonts fall back to the platform default for that family.
/// - Inline `style="background-color: …"` survives but block-level
///   `background-color` on `<body>` / `<html>` is dropped (the
///   importer treats those as page-level chrome which native text views
///   cannot render anyway).
/// - The returned `AttributedString`'s character offsets are **not**
///   guaranteed to line up with `chapter.text` offsets. `chapter.text`
///   goes through a separate pipeline (inline footnote-body injection,
///   forced line breaks before em dashes) that this HTML render does not
///   replicate. Any future text-selection → bookmark/highlight feature
///   must not assume `NSRange` from a selection in the rendered view can
///   be used directly as a `chapter.text` char offset — it needs its own
///   mapping (or a shared source of truth) instead.
@MainActor
enum EpubHtmlRenderer {

    /// Convert a chapter's raw HTML + CSS into a native-renderable
    /// `AttributedString`, applying any overrides from `settings`.
    ///
    /// Returns `nil` when:
    ///   - `html` is empty / whitespace-only (caller falls back to
    ///     `chapter.text` rendered as plain text), OR
    ///   - the importer fails outright (malformed HTML, encoding
    ///     errors, etc.) — same fallback.
    static func render(
        html: String,
        css: String?,
        settings: AppSettings,
        fontDirectoryURL: URL? = nil,
        resources: [EbookFulltext.Chapter.Resource]? = nil
    ) -> AttributedString? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let body = extractBodyContent(trimmed)
        // Cocoa's HTML importer drops fragment-only `href="#note"` links.
        // Rewrite every EPUB-local target to an app-owned URL first so both
        // fragment and cross-document destinations survive as `.link` runs.
        let linkedBody = rewriteInternalLinkHrefs(body)
        let resolvedBody = EpubResourcePresentation.resolveResourceImageSources(linkedBody, resources: resources ?? [])
        let (placeholderBody, images) = EpubResourcePresentation.extractDataURIImages(resolvedBody)
        let cleanedCSS: String = {
            let sourceCSS = css ?? ""
            if sourceCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return """
                p { text-align: justify; margin-top: 0; margin-bottom: 0.7em; text-indent: 1.5em; }
                h1, h2, h3, h4, h5, h6 { text-align: center; margin-top: 1em; margin-bottom: 0.8em; text-indent: 0; }
                """
            }
            return EpubResourcePresentation.rewriteFontFaceURLs(sourceCSS, fontDirectory: fontDirectoryURL)
        }()

        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>\(cleanedCSS)</style>
        </head><body>\(placeholderBody)</body></html>
        """

        guard let data = doc.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let imported = try? NSAttributedString(
            data: data, options: options, documentAttributes: nil
        ) else {
            return nil
        }
        // The Foundation HTML importer can succeed with an empty attributed
        // string for malformed/fragment-only EPUB documents. Treat that as a
        // failed render so the reader can use the parser's plain-text payload
        // instead of displaying a blank page.
        guard !imported.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let mutated = NSMutableAttributedString(attributedString: imported)
        EpubResourcePresentation.inlineImageAttachments(images, into: mutated)
        let bodyFontSize = EpubFontPresentation.modalBodyFontSize(in: imported)
        EpubParagraphPresentation.applyStructuralParagraphStyles(
            to: mutated,
            html: resolvedBody,
            css: cleanedCSS,
            bodyFontSize: bodyFontSize
        )
        EpubFontPresentation.applyOverrides(to: mutated, settings: settings, bodyFontSize: bodyFontSize)
        return AttributedString(mutated)
    }

    /// Conservative fallback for EPUB fragments that Foundation's HTML
    /// importer cannot render. It keeps readable text visible even when the
    /// parser supplied HTML but omitted the parallel plain-text field.
    static func plainText(from html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Converts a raw EPUB-local href into a stable URL that the native
    /// reader handles itself. Public web/mail/phone links deliberately keep
    /// their original scheme so UIKit can hand them to the system.
    static func readerLinkURL(for rawHref: String) -> URL? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme) {
            return url
        }
        var components = URLComponents()
        components.scheme = "epub-link"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: trimmed)]
        return components.url
    }

    private static func rewriteInternalLinkHrefs(_ html: String) -> String {
        let pattern = try! NSRegularExpression(
            pattern: "(?i)(<a\\b[^>]*\\bhref\\s*=\\s*)([\\\"'])([^\\\"']*)(\\2)"
        )
        var rewritten = html
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let rawRange = Range(match.range(at: 3), in: html),
                  let url = readerLinkURL(for: String(html[rawRange])) else { continue }
            let replacement = url.absoluteString
            guard let replacementRange = Range(match.range(at: 3), in: rewritten) else { continue }
            rewritten.replaceSubrange(replacementRange, with: replacement)
        }
        return rewritten
    }

    // MARK: - HTML / CSS sanitisation

    private static func extractBodyContent(_ html: String) -> String {
        guard let bodyStart = html.range(of: #"<body[^>]*>"#, options: .regularExpression),
              let bodyEnd = html.range(of: "</body>", options: .backwards) else {
            return html.replacingOccurrences(
                of: #"<link\b[^>]*>"#, with: "", options: .regularExpression
            )
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }


}
