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
}
