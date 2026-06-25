import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

// MARK: - Environment key for EPUB font directory

/// The temp directory where `EpubFontManager` extracted the EPUB's
/// embedded font files. Set by `BookOpenView` after registration;
/// consumed by `ReaderView` when invoking `EpubHtmlRenderer.render`.
private struct EpubFontDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var epubFontDirectory: URL? {
        get { self[EpubFontDirectoryKey.self] }
        set { self[EpubFontDirectoryKey.self] = newValue }
    }
}

/// Renders a chapter's raw HTML body + per-chapter CSS into an
/// AttributedString suitable for SwiftUI `Text(_:)`, then layers the
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
///   importer treats those as page-level chrome which SwiftUI's
///   `Text` can't render anyway).
@MainActor
enum EpubHtmlRenderer {

    /// Convert a chapter's raw HTML + CSS into a SwiftUI-renderable
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
        fontDirectoryURL: URL? = nil
    ) -> AttributedString? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bodyContent = stripImageSources(extractBodyContent(trimmed))
        let cleanedCSS = rewriteFontFaceURLs(css ?? "", fontDirectory: fontDirectoryURL)

        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>\(cleanedCSS)</style>
        </head><body>\(bodyContent)</body></html>
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

        let mutated = NSMutableAttributedString(attributedString: imported)
        let bodyFontSize = modalBodyFontSize(in: imported)
        applyOverrides(to: mutated, settings: settings, bodyFontSize: bodyFontSize)
        return AttributedString(mutated)
    }

    /// The most common font size across the chapter — i.e. the body text
    /// size. Headings (`<h1>`–`<h6>`) render LARGER than this via the
    /// importer's CSS, so a run whose size exceeds the modal size is a
    /// heading. This is content-agnostic: it keys on the EPUB's own
    /// declared typography, never on how long a paragraph happens to be.
    private static func modalBodyFontSize(in attr: NSAttributedString) -> CGFloat {
        guard attr.length > 0 else { return 0 }
        var histogram: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
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

        let targetSize = settings.readerPointSize
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

        attr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            // ---- Font ----------------------------------------------
            let baseFont = (attrs[.font] as? PlatformFont)
                ?? PlatformFont.systemFont(ofSize: targetSize)
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
    // so the renderer doesn't need to import SwiftUI's `Color`
    // (AttributedString stores platform colours, not SwiftUI's).

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
