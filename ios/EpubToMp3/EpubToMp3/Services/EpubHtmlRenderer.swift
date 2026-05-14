import Foundation
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor

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
        settings: AppSettings
    ) -> AttributedString? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Wrap the body in a tiny doc so the EPUB's own CSS applies
        // before the importer tokenises. `meta charset` keeps the
        // importer from misreading non-ASCII as MacRoman.
        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>\(css ?? "")</style>
        </head><body>\(trimmed)</body></html>
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
        applyOverrides(to: mutated, settings: settings)
        return AttributedString(mutated)
    }

    // MARK: Override pipeline

    /// Walks every run and rewrites attributes per the user's
    /// override flags. Each branch is gated so the EPUB's own
    /// declared font / colour / weight survives untouched when the
    /// override is off.
    private static func applyOverrides(
        to attr: NSMutableAttributedString,
        settings: AppSettings
    ) {
        let fullRange = NSRange(location: 0, length: attr.length)
        guard fullRange.length > 0 else { return }

        let overrideFamily = settings.readerOverrideFontFamily
        let overrideSize = settings.readerOverrideFontSize
        let overrideColours = settings.readerOverrideColours
        let boldAll = settings.readerBoldOverride
        let suppressItalic = settings.readerSuppressItalic
        let letterSpacing = settings.readerLetterSpacing

        let targetSize = settings.readerPointSize
        let targetFamily = familyName(for: settings.readerFontFamily)
        let targetFG = resolvedForeground(for: settings)
        let targetBG = resolvedBackground(for: settings)

        attr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            // ---- Font ----------------------------------------------
            let baseFont = (attrs[.font] as? PlatformFont)
                ?? PlatformFont.systemFont(ofSize: targetSize)
            let mutatedFont = mutateFont(
                baseFont,
                family: overrideFamily ? targetFamily : nil,
                size: overrideSize ? targetSize : nil,
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
        if forceBold { traits.insert(.traitBold) }
        if stripItalic { traits.remove(.traitItalic) }
        if let withTraits = descriptor.withSymbolicTraits(traits) {
            descriptor = withTraits
        }
        return UIFont(descriptor: descriptor, size: pointSize)
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
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }
}
