import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
private typealias EpubInlineImage = UIImage
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
private typealias EpubInlineImage = NSImage
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
        let resolvedBody = resolveResourceImageSources(linkedBody, resources: resources ?? [])
        let (placeholderBody, images) = extractDataURIImages(resolvedBody)
        let cleanedCSS: String = {
            let sourceCSS = css ?? ""
            if sourceCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return """
                p { text-align: justify; margin-top: 0; margin-bottom: 0.7em; text-indent: 1.5em; }
                h1, h2, h3, h4, h5, h6 { text-align: center; margin-top: 1em; margin-bottom: 0.8em; text-indent: 0; }
                """
            }
            return rewriteFontFaceURLs(sourceCSS, fontDirectory: fontDirectoryURL)
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
        guard let imported = try? unsafe NSAttributedString(
            data: data, options: options, documentAttributes: nil
        ) else {
            return nil
        }

        let mutated = NSMutableAttributedString(attributedString: imported)
        inlineImageAttachments(images, into: mutated)
        let bodyFontSize = modalBodyFontSize(in: imported)
        applyStructuralParagraphStyles(
            to: mutated,
            html: resolvedBody,
            css: cleanedCSS,
            bodyFontSize: bodyFontSize
        )
        applyOverrides(to: mutated, settings: settings, bodyFontSize: bodyFontSize)
        return AttributedString(mutated)
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

    private static func applyStructuralParagraphStyles(
        to attr: NSMutableAttributedString,
        html: String,
        css: String,
        bodyFontSize: CGFloat
    ) {
        guard attr.length > 0 else { return }
        let source = html as NSString
        let blockRegex = try? NSRegularExpression(
            pattern: "(?is)<(p|h[1-6]|blockquote|li)\\b([^>]*)>"
        )
        let blockMatches = blockRegex?.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        ) ?? []
        guard !blockMatches.isEmpty else { return }

        var paragraphRanges: [NSRange] = []
        var cursor = 0
        let rendered = attr.string as NSString
        while cursor < rendered.length {
            let range = rendered.paragraphRange(for: NSRange(location: cursor, length: 0))
            paragraphRanges.append(range)
            let next = NSMaxRange(range)
            cursor = next > cursor ? next : cursor + 1
        }

        for (index, match) in blockMatches.enumerated() where index < paragraphRanges.count {
            let tag = source.substring(with: match.range(at: 1)).lowercased()
            let attributes = source.substring(with: match.range(at: 2))
            let classes = classNames(in: attributes)
            let declarations = cssDeclarations(
                for: tag,
                classes: classes,
                css: css
            )
            let inline = cssDeclarations(from: inlineStyle(in: attributes))
            let merged = declarations.merging(inline) { _, inlineValue in inlineValue }
            guard merged["text-indent"] != nil || merged["margin-top"] != nil || merged["margin-bottom"] != nil else {
                continue
            }

            let range = paragraphRanges[index]
            let style = (unsafe attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            if let value = merged["text-indent"] {
                style.firstLineHeadIndent = cssLength(value, bodyFontSize: bodyFontSize)
            }
            if let value = merged["margin-top"] {
                style.paragraphSpacingBefore = cssLength(value, bodyFontSize: bodyFontSize)
            }
            if let value = merged["margin-bottom"] {
                style.paragraphSpacing = cssLength(value, bodyFontSize: bodyFontSize)
            }
            attr.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private static func classNames(in attributes: String) -> [String] {
        guard let match = try? NSRegularExpression(pattern: "(?i)class\\s*=\\s*[\\\"']([^\\\"']+)")
            .firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
              match.numberOfRanges > 1 else { return [] }
        let ns = attributes as NSString
        return ns.substring(with: match.range(at: 1))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private static func inlineStyle(in attributes: String) -> String {
        guard let match = try? NSRegularExpression(pattern: "(?i)style\\s*=\\s*[\\\"']([^\\\"']+)")
            .firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
              match.numberOfRanges > 1 else { return "" }
        return (attributes as NSString).substring(with: match.range(at: 1))
    }

    private static func cssDeclarations(for tag: String, classes: [String], css: String) -> [String: String] {
        let rules = try? NSRegularExpression(pattern: "(?s)([^{}]+)\\{([^{}]*)\\}")
        let ns = css as NSString
        var result: [String: String] = [:]
        for rule in rules?.matches(in: css, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let selectors = ns.substring(with: rule.range(at: 1)).lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let matches = selectors.contains { selector in
                selector == tag || classes.contains { className in
                    selector == ".\(className.lowercased())"
                        || selector.hasSuffix(" .\(className.lowercased())")
                        || selector.hasSuffix(">.\(className.lowercased())")
                }
            }
            if matches { result.merge(cssDeclarations(from: ns.substring(with: rule.range(at: 2)))) { _, new in new } }
        }
        return result
    }

    private static func cssDeclarations(from text: String) -> [String: String] {
        text.split(separator: ";").reduce(into: [:]) { result, item in
            let pair = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
    }

    private static func cssLength(_ raw: String, bodyFontSize: CGFloat) -> CGFloat {
        let pattern = "^\\s*([+-]?[0-9]*\\.?[0-9]+)\\s*(pt|px|em|rem|%)?"
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)),
              let number = Double((raw as NSString).substring(with: match.range(at: 1))) else { return 0 }
        let unit: String
        if match.numberOfRanges > 2 {
            let unitRange = match.range(at: 2)
            unit = unitRange.location != NSNotFound
                ? (raw as NSString).substring(with: unitRange).lowercased()
                : "pt"
        } else {
            unit = "pt"
        }
        switch unit {
        case "em", "rem": return CGFloat(number) * max(bodyFontSize, 16)
        case "px": return CGFloat(number) * 0.75
        case "%": return CGFloat(number) * max(bodyFontSize, 16) / 100
        default: return CGFloat(number)
        }
    }

    /// The most common font size across the chapter — i.e. the body text
    /// size. Headings (`<h1>`–`<h6>`) render LARGER than this via the
    /// importer's CSS, so a run whose size exceeds the modal size is a
    /// heading. This is content-agnostic: it keys on the EPUB's own
    /// declared typography, never on how long a paragraph happens to be.
    private static func modalBodyFontSize(in attr: NSAttributedString) -> CGFloat {
        guard attr.length > 0 else { return 0 }
        var histogram: [CGFloat: Int] = [:]
        unsafe attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let f = value as? PlatformFont else { return }
            // Weight by character count so a long body dominates over a
            // short heading even if there are several headings.
            histogram[f.pointSize, default: 0] += range.length
        }
        return histogram.max(by: { $0.value < $1.value })?.key ?? 0
    }

    // MARK: Override pipeline

    /// Walks every run and rewrites attributes per the user's
    /// override flags. Each branch is gated so the EPUB's own
    /// declared font / colour / weight survives untouched when the
    /// override is off.
    private static func applyOverrides(
        to attr: NSMutableAttributedString,
        settings: AppSettings,
        bodyFontSize: CGFloat
    ) {
        let fullRange = NSRange(location: 0, length: attr.length)
        guard fullRange.length > 0 else { return }

        let overrideFamily = settings.readerOverrideFontFamily
        let overrideSize = settings.readerOverrideFontSize
        // Override the EPUB's hardcoded colours for every theme except
        // `.light`. `.auto` USED to opt out — but the EPUB's CSS almost
        // always pins `color: #000` (black) on body text and assumes a
        // white page, so opening the book in system Dark Mode gave
        // black-on-black: invisible text. We now substitute the
        // theme's resolved foreground (which is `.label` — the
        // dynamic system colour that flips with appearance) in
        // `.auto` so dark mode renders white text on dark, light mode
        // renders black on white.
        let overrideColours = settings.readerOverrideColours
            || settings.readerTheme != .light
        let boldAll = settings.readerBoldOverride
        let suppressItalic = settings.readerSuppressItalic
        let letterSpacing = settings.readerLetterSpacing

        #if canImport(UIKit)
        let targetSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: settings.readerPointSize)
        #else
        let targetSize = settings.readerPointSize
        #endif
        let targetFamily = familyName(for: settings.readerFontFamily)
        let targetFG = resolvedForeground(for: settings)
        let targetBG = resolvedBackground(for: settings)

        // Cap EPUB CSS font sizes at `targetSize * 1.5` even when the
        // user has not enabled `readerOverrideFontSize`. Some EPUBs
        // declare 2x+ heading scales (e.g. `h1 { font-size: 2.5em }`)
        // which renders as 40-60 pt text and overflows the paginated
        // page on iPhone — visible to the user as "texto grande" on
        // app open and on every chapter that begins with a heading.
        // 1.5x keeps the heading visually distinct from body text
        // without breaking pagination.
        let maxHeadingSize = targetSize * 1.5

        unsafe attr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            // ---- Font ----------------------------------------------
            let baseFont = (attrs[.font] as? PlatformFont)
                ?? serifFallbackFont(ofSize: targetSize)
            let cappedSize: CGFloat? = overrideSize
                ? targetSize
                : (baseFont.pointSize > maxHeadingSize ? maxHeadingSize : nil)
            let mutatedFont = mutateFont(
                baseFont,
                family: overrideFamily ? targetFamily : nil,
                size: cappedSize,
                forceBold: boldAll,
                stripItalic: suppressItalic
            )
            attr.addAttribute(.font, value: mutatedFont, range: range)

            // ---- Colours -------------------------------------------
            if overrideColours {
                attr.addAttribute(.foregroundColor, value: targetFG, range: range)
                if let targetBG {
                    attr.addAttribute(.backgroundColor, value: targetBG, range: range)
                } else {
                    attr.removeAttribute(.backgroundColor, range: range)
                }
            }

            // ---- Kerning -------------------------------------------
            if letterSpacing != 0 {
                attr.addAttribute(.kern, value: NSNumber(value: letterSpacing), range: range)
            }

            // ---- Paragraph spacing normalisation ------------------
            // EPUB CSS frequently sets paragraph-spacing-before /
            // margin-top on body paragraphs to 1em-3em, plus huge
            // h1/h2 bottom margins. The importer translates those to
            // `paragraphSpacing` / `paragraphSpacingBefore` on the
            // `NSParagraphStyle` for the range. TextKit honours them
            // exactly, which is why page 1 of a chapter often shows
            // a giant title and only one or two body lines — the
            // h1's `paragraphSpacing` pushes the next paragraph past
            // half the page. Cap both values so the paginator can
            // fill the page like Apple Books does (it strips most
            // EPUB whitespace and runs its own typography).
            // Build the paragraph style: start from whatever the EPUB
            // declared (so paragraph-spacing / firstLineHeadIndent /
            // line-height etc. are preserved), then clamp the abusive
            // values, then force the user's alignment choice. When the
            // EPUB declared no paragraph style at all (rare — most
            // imports synthesise one), create a fresh
            // `NSMutableParagraphStyle` so the alignment still lands.
            let mutable: NSMutableParagraphStyle = {
                if let original = attrs[.paragraphStyle] as? NSParagraphStyle,
                   let copy = original.mutableCopy() as? NSMutableParagraphStyle {
                    return copy
                }
                return NSMutableParagraphStyle()
            }()
            let maxSpacing: CGFloat = targetSize * 0.8       // ~80% of a line
            if mutable.paragraphSpacing > maxSpacing {
                mutable.paragraphSpacing = maxSpacing
            }
            if mutable.paragraphSpacingBefore > maxSpacing {
                mutable.paragraphSpacingBefore = maxSpacing
            }
            mutable.lineSpacing = CGFloat(settings.readerLineSpacing)
            // Some EPUBs set firstLineHeadIndent for drop-cap
            // styling; that interacts badly with paginated
            // layout. Clamp to 0..targetSize (one em).
            if mutable.firstLineHeadIndent > targetSize {
                mutable.firstLineHeadIndent = targetSize
            }
            // Preserve the EPUB's INTENTIONAL centred/right alignment only
            // for HEADINGS — detected structurally by the EPUB's OWN
            // typography: a heading run renders larger than the chapter's
            // modal (body) font size, exactly as the book's CSS declared.
            // This is content-agnostic — it never keys on paragraph length
            // or specific text — so a long centred title is kept while a
            // body paragraph that merely inherited `text-align:center` from
            // a wrapping container follows the user's alignment choice
            // (fixing "o texto todo ta centralizado"). Body paragraphs at
            // or below the body size always take the user's alignment.
            let epubAlignment = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment
            let isHeadingRun = bodyFontSize > 0 && baseFont.pointSize > bodyFontSize + 0.5
            if (epubAlignment == .center || epubAlignment == .right), isHeadingRun {
                mutable.alignment = epubAlignment!
            } else {
                mutable.alignment = settings.readerTextAlignment == .justified
                    ? .justified
                    : .left
            }
            attr.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
    }

    private static func serifFallbackFont(ofSize size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        return UIFont(name: "NewYork", size: size)
            ?? UIFont(name: "Georgia", size: size)
            ?? UIFont.systemFont(ofSize: size)
        #else
        return NSFont(name: "New York", size: size)
            ?? NSFont(name: "Georgia", size: size)
            ?? NSFont.systemFont(ofSize: size)
        #endif
    }

    // MARK: Font mutation

    private static func mutateFont(
        _ base: PlatformFont,
        family: String?,
        size: CGFloat?,
        forceBold: Bool,
        stripItalic: Bool
    ) -> PlatformFont {
        let pointSize = size ?? base.pointSize
        var descriptor = base.fontDescriptor
        if let family {
            descriptor = descriptor.withFamily(family)
        }
        var traits = descriptor.symbolicTraits
        #if canImport(UIKit)
        if forceBold { traits.insert(.traitBold) }
        if stripItalic { traits.remove(.traitItalic) }
        #else
        if forceBold { traits.insert(.bold) }
        if stripItalic { traits.remove(.italic) }
        #endif
        #if canImport(UIKit)
        if let withTraits = descriptor.withSymbolicTraits(traits) {
            descriptor = withTraits
        }
        #else
        descriptor = descriptor.withSymbolicTraits(traits)
        #endif
        #if canImport(UIKit)
        return PlatformFont(descriptor: descriptor, size: pointSize)
        #else
        return PlatformFont(descriptor: descriptor, size: pointSize) ?? base
        #endif
    }

    private static func familyName(for family: ReaderFontFamily) -> String {
        switch family {
        case .serif: return "Times New Roman"
        case .sans:  return "Helvetica Neue"
        case .mono:  return "Menlo"
        }
    }

    // MARK: Colour resolution
    //
    // We mirror `ReaderView.themeBackground` / `themeForeground` here
    // so the renderer stays independent of the UI framework.

    private static func resolvedForeground(for settings: AppSettings) -> PlatformColor {
        switch settings.readerTheme {
        #if canImport(UIKit)
        case .auto:      return .label
        #else
        case .auto:      return .labelColor
        #endif
        case .light:     return .black
        case .sepia:     return rgb(0.20, 0.15, 0.10)
        case .parchment: return rgb(0.18, 0.13, 0.06)
        case .paper:     return rgb(0.10, 0.10, 0.10)
        case .dark:      return rgb(0.92, 0.92, 0.92)
        case .black:     return rgb(0.95, 0.95, 0.95)
        case .custom:
            let fg = settings.readerCustomColors.foreground
            return rgb(fg.0, fg.1, fg.2)
        }
    }

    /// Background returned as optional because for `.light` /
    /// transparent themes we'd rather strip the attribute than paint
    /// over inline highlights with white.
    private static func resolvedBackground(for settings: AppSettings) -> PlatformColor? {
        switch settings.readerTheme {
        case .auto:      return nil
        case .light:     return nil
        case .sepia:     return rgb(0.96, 0.93, 0.85)
        case .parchment: return rgb(0.94, 0.89, 0.78)
        case .paper:     return rgb(0.98, 0.97, 0.94)
        case .dark:      return rgb(0.12, 0.12, 0.14)
        case .black:     return .black
        case .custom:
            let bg = settings.readerCustomColors.background
            return rgb(bg.0, bg.1, bg.2)
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> PlatformColor {
        PlatformColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
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

    private static func stripImageSources(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"(<img\b[^>]*)\bsrc\s*=\s*("[^"]*"|'[^']*')"#,
            with: "$1",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"(<image\b[^>]*)\bxlink:href\s*=\s*("[^"]*"|'[^']*')"#,
            with: "$1",
            options: .regularExpression
        )
    }

    /// Replace EPUB-relative image references with bounded, local data URIs.
    /// Resource hrefs are matched after percent-decoding and removing query/
    /// fragment suffixes; `data:` and remote URLs remain untouched.
    private static func resolveResourceImageSources(
        _ html: String,
        resources: [EbookFulltext.Chapter.Resource]
    ) -> String {
        guard !resources.isEmpty else { return html }
        var byHref: [String: EbookFulltext.Chapter.Resource] = [:]
        for resource in resources {
            byHref[normalisedResourceHref(resource.href)] = resource
        }
        let pattern = try! NSRegularExpression(
            pattern: #"(?i)(<img\b[^>]*\bsrc\s*=\s*)([\"'])([^\"']+)(\2)"#
        )
        var result = html
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let srcRange = Range(match.range(at: 3), in: result) else { continue }
            let source = String(result[srcRange])
            guard !source.lowercased().hasPrefix("data:") else { continue }
            guard let resource = byHref[normalisedResourceHref(source)],
                  let encoded = resource.dataBase64,
                  let data = Data(base64Encoded: encoded),
                  !data.isEmpty else { continue }
            let mediaType = resource.mediaType ?? mimeType(for: source)
            let dataURI = "data:\(mediaType);base64,\(data.base64EncodedString())"
            result.replaceSubrange(srcRange, with: dataURI)
        }
        return result
    }

    private static func normalisedResourceHref(_ href: String) -> String {
        let withoutSuffix = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let withoutQuery = withoutSuffix.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutSuffix
        return (withoutQuery.removingPercentEncoding ?? withoutQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func mimeType(for href: String) -> String {
        switch URL(fileURLWithPath: href).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// `NSAttributedString`'s HTML importer does not turn `<img>` tags
    /// into `.attachment` runs — it silently drops them. To keep inline
    /// EPUB images (already inlined as `data:` URIs by the caller) we
    /// swap each `<img src="data:...">` for a unique text placeholder
    /// before import, then splice a real `NSTextAttachment` back in at
    /// the placeholder's resolved range.
    private static func extractDataURIImages(_ html: String) -> (String, [(token: String, image: EpubInlineImage)]) {
        var images: [(token: String, image: EpubInlineImage)] = []
        var result = ""
        var searchStart = html.startIndex
        var counter = 0

        while let match = html.range(
            of: #"<img\b[^>]*\bsrc\s*=\s*"data:image/[^;"]+;base64,[^"]*"[^>]*>"#,
            options: .regularExpression,
            range: searchStart..<html.endIndex
        ) {
            result += html[searchStart..<match.lowerBound]
            let tag = String(html[match])
            if let base64Range = tag.range(of: #"base64,[^"]*"#, options: .regularExpression) {
                let base64 = tag[base64Range].dropFirst("base64,".count)
                if let bytes = Data(base64Encoded: String(base64)),
                   let image = downsampledInlineImage(from: bytes) {
                    let token = "EPUBIMGPLACEHOLDER\(counter)EPUBIMGPLACEHOLDER"
                    counter += 1
                    images.append((token, image))
                    result += token
                } else {
                    // Undecodable payload — drop the tag rather than leak base64 text.
                }
            }
            searchStart = match.upperBound
        }
        result += html[searchStart..<html.endIndex]
        return (result, images)
    }

    /// Largest edge (in pixels) an inline EPUB image is decoded to.
    /// A paginated iPhone reader page is <=1290pt wide on the biggest
    /// device; 1400px covers @2x/@3x without over-allocating. The old
    /// path fed raw base64 bytes straight into `UIImage(data:)`, which
    /// decompresses to the FULL source resolution — a single 3000x3000
    /// EPUB illustration became a ~36 MB resident bitmap, and the
    /// scroll-mode buffer renders the current chapter plus both
    /// neighbours, so 3 image-heavy chapters could spike hundreds of MB
    /// on the main thread the instant the reader/player mounted. On an
    /// 8 GB device with the WidgetKit extension also being reloaded on
    /// the play burst, that memory storm is what forced a full device
    /// reboot (jetsam could not reclaim fast enough). Capping the decode
    /// here keeps each attachment bounded regardless of source size.
    private static let inlineImageMaxPixels = 1400

    /// Decode EPUB inline image bytes to a bitmap whose largest edge is
    /// at most `inlineImageMaxPixels`, using ImageIO's thumbnail path so
    /// the full-resolution bitmap is never allocated. Falls back to the
    /// plain decoder only when ImageIO cannot read the source (keeps
    /// exotic formats working), and that fallback is itself size-checked
    /// by the caller's format support — the common heavy case (large
    /// JPEG/PNG illustrations) always takes the bounded path.
    private static func downsampledInlineImage(from data: Data) -> EpubInlineImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return EpubInlineImage(data: data)
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: inlineImageMaxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return EpubInlineImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private static func inlineImageAttachments(
        _ images: [(token: String, image: EpubInlineImage)],
        into attr: NSMutableAttributedString
    ) {
        for (token, image) in images {
            let plain = attr.string as NSString
            let range = plain.range(of: token)
            guard range.location != NSNotFound else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            attr.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
    }

    /// Rewrite `@font-face src: url(...)` declarations to point at
    /// the local temp directory where `EpubFontManager` extracted the
    /// font files. When no font directory is available (fonts not
    /// registered), falls back to stripping the URLs entirely so the
    /// importer doesn't attempt to fetch unreachable EPUB-internal paths.
    private static func rewriteFontFaceURLs(_ css: String, fontDirectory: URL?) -> String {
        guard let fontDir = fontDirectory else {
            // No fonts extracted — strip src declarations to avoid
            // the importer choking on relative EPUB paths.
            return css.replacingOccurrences(
                of: #"src:\s*url\([^)]*\)\s*;?"#,
                with: "",
                options: .regularExpression
            ).replacingOccurrences(
                of: #"@import\s+url\([^)]*\)\s*;?"#,
                with: "",
                options: .regularExpression
            )
        }

        let dirPath = fontDir.path
        // Rewrite each `src: url(...)` to a file:// URL pointing at
        // the extracted font file (filename only — EpubFontManager
        // flattens the EPUB's nested font paths into one directory).
        let srcPattern = try! NSRegularExpression(
            pattern: #"src:\s*url\(\s*['"]?([^'")]+)['"]?\s*\)"#
        )

        var result = css
        let matches = srcPattern.matches(
            in: css, range: NSRange(css.startIndex..., in: css)
        ).reversed()  // reverse so indices stay valid after mutation

        for match in matches {
            guard let wholeRange = Range(match.range, in: result),
                  let pathRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let originalPath = String(result[pathRange])
            // Extract just the filename (last path component)
            let filename = (originalPath as NSString).lastPathComponent
            // Strip query strings / fragments from the filename
            let cleanFilename = filename.components(separatedBy: "?").first?
                .components(separatedBy: "#").first ?? filename
            let localURL = URL(fileURLWithPath: dirPath)
                .appendingPathComponent(cleanFilename)

            if FileManager.default.fileExists(atPath: localURL.path) {
                let replacement = "src: url('\(localURL.absoluteString)')"
                result.replaceSubrange(wholeRange, with: replacement)
            } else {
                // Font file not found in temp dir — strip the declaration
                // so the importer doesn't error on a missing file.
                result.replaceSubrange(wholeRange, with: "")
            }
        }

        // Still strip @import url(...) — those reference stylesheets,
        // not fonts, and won't resolve from the EPUB bundle.
        result = result.replacingOccurrences(
            of: #"@import\s+url\([^)]*\)\s*;?"#,
            with: "",
            options: .regularExpression
        )
        return result
    }
}
