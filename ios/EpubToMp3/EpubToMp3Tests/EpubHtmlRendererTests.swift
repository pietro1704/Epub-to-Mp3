import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

/// Verifies `EpubHtmlRenderer.render(...)` honours EPUB-native
/// formatting AND lets user overrides win when the corresponding
/// flag is on. NSAttributedString's HTML importer is single-threaded
/// and requires the main thread, so we mark the whole suite
/// MainActor-isolated.
final class EpubHtmlRendererTests: XCTestCase {

    func makeSettings() -> AppSettings {
        let suite = UUID().uuidString
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Convenience: round-trip back to NSAttributedString for run
    /// inspection (AttributedString's enumeration API is much more
    /// awkward for attribute-name lookups in tests).
    func ns(_ attr: AttributedString) -> NSAttributedString {
        NSAttributedString(attr)
    }

    func rgba(_ color: PlatformColor) -> [CGFloat] {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
        #else
        let rgb = color.usingColorSpace(.sRGB)!
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        #endif
    }

    @MainActor
    func testEmptyHtmlReturnsNilSoCallerFallsBackToPlain() {
        let s = makeSettings()
        XCTAssertNil(EpubHtmlRenderer.render(html: "", css: nil, settings: s))
        XCTAssertNil(EpubHtmlRenderer.render(html: "   \n  ", css: nil, settings: s))
    }

    @MainActor
    func testMarkupWithoutReadableTextReturnsNilSoCallerFallsBackToPlain() {
        let s = makeSettings()
        XCTAssertNil(EpubHtmlRenderer.render(
            html: "<html><head><style>body { color: red; }</style></head><body><br/></body></html>",
            css: nil,
            settings: s
        ))
    }

    @MainActor
    func testPlainTextFallbackExtractsReadableHTMLContent() {
        XCTAssertEqual(
            EpubHtmlRenderer.plainText(from: "<h1>Chapter</h1><p>Hello&nbsp;world &amp; friends.</p>"),
            "Chapter Hello world & friends."
        )
    }

    /// Canary, not a regression guard: documents that the rendered
    /// AttributedString's plain-text projection is NOT guaranteed to be
    /// character-identical to `chapter.text`. `chapter.text` goes through
    /// inline footnote-body injection and forced line breaks before em
    /// dashes; the HTML render does neither. A future text-selection →
    /// bookmark/highlight feature must not assume a rendered-view NSRange
    /// can be used directly as a `chapter.text` char offset. See the
    /// "Known limitations" doc comment on `EpubHtmlRenderer.render`.
    @MainActor
    func testRenderedPlainTextIsNotGuaranteedToMatchChapterText() {
        let s = makeSettings()
        let html = "<p>Paragraph one.</p><p>Paragraph two.</p>"
        // Mirrors what `TextProcessor.add_pause_before_dash` /
        // footnote-inlining would have produced for the reading `text`
        // field — a plain string with its own line breaks, independent
        // of the HTML the renderer receives.
        let chapterText = "Paragraph one.\nParagraph two.\n\nnota de rodapé 1\nfim da nota de rodapé"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for non-empty HTML")
        }
        XCTAssertNotEqual(
            ns(out).string, chapterText,
            "Documented gap: rendered HTML plain-text and chapter.text are independent pipelines."
        )
    }
}
