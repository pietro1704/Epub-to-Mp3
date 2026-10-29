import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
enum EpubFontPresentation {
    /// The most common font size across the chapter — i.e. the body text
    /// size. Headings (`<h1>`–`<h6>`) render LARGER than this via the
    /// importer's CSS, so a run whose size exceeds the modal size is a
    /// heading. This is content-agnostic: it keys on the EPUB's own
    /// declared typography, never on how long a paragraph happens to be.
    static func modalBodyFontSize(in attr: NSAttributedString) -> CGFloat {
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
    static func applyOverrides(
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
        let colors = settings.readerColors

        attr.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            // ---- Font ----------------------------------------------
            let baseFont = (attrs[.font] as? PlatformFont)
                ?? serifFallbackFont(ofSize: targetSize)
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
                attr.addAttribute(.foregroundColor,
                                  value: attrs[.link] == nil ? colors.foreground : colors.link,
                                  range: range)
                // The native page owns the background. Publisher run backgrounds
                // must not form rectangles against a different theme surface.
                attr.removeAttribute(.backgroundColor, range: range)
            } else if attrs[.foregroundColor] == nil {
                // The importer can omit the default foreground. Give these
                // runs a native color rather than inheriting the text view's
                // previous theme, while keeping explicit publisher colors.
                attr.addAttribute(.foregroundColor,
                                  value: attrs[.link] == nil ? colors.foreground : colors.link,
                                  range: range)
            }

            // ---- Kerning -------------------------------------------
            if letterSpacing != 0 {
                attr.addAttribute(.kern, value: NSNumber(value: letterSpacing), range: range)
            }

            // Publisher paragraphs remain untouched until a reader control
            // explicitly overrides alignment or line spacing. The viewport
            // module owns non-clipping layout, including oversized fragments.
            guard settings.readerOverrideTextAlignment || settings.readerOverrideLineSpacing else { return }
            let mutable: NSMutableParagraphStyle = {
                if let original = attrs[.paragraphStyle] as? NSParagraphStyle,
                   let copy = original.mutableCopy() as? NSMutableParagraphStyle {
                    return copy
                }
                return NSMutableParagraphStyle()
            }()
            if settings.readerOverrideLineSpacing { mutable.lineSpacing = CGFloat(settings.readerLineSpacing) }
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
            if settings.readerOverrideTextAlignment {
                if (epubAlignment == .center || epubAlignment == .right), isHeadingRun {
                    mutable.alignment = epubAlignment!
                } else {
                    mutable.alignment = settings.readerTextAlignment == .justified ? .justified : .left
                }
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


}
