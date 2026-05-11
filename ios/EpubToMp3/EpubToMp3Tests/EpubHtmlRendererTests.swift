import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

/// Verifies `EpubHtmlRenderer.render(...)` honours EPUB-native
/// formatting AND lets user overrides win when the corresponding
/// flag is on. NSAttributedString's HTML importer is single-threaded
/// and requires the main thread, so we mark the whole suite
/// MainActor-isolated.
@MainActor
final class EpubHtmlRendererTests: XCTestCase {

    private func makeSettings() -> AppSettings {
        let suite = UUID().uuidString
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Convenience: round-trip back to NSAttributedString for run
    /// inspection (AttributedString's enumeration API is much more
    /// awkward for attribute-name lookups in tests).
    private func ns(_ attr: AttributedString) -> NSAttributedString {
        NSAttributedString(attr)
    }

    func testRendersBoldAndItalic() {
        let s = makeSettings()
        let html = "<p><b>hi</b> <i>there</i></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for non-empty HTML")
        }
        let n = ns(out)
        let plain = n.string
        XCTAssertTrue(plain.contains("hi"))
        XCTAssertTrue(plain.contains("there"))

        var sawBold = false
        var sawItalic = false
        n.enumerateAttribute(.font, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            #if canImport(AppKit)
            guard let f = value as? NSFont else { return }
            let traits = f.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { sawBold = true }
            if traits.contains(.italic) { sawItalic = true }
            #endif
        }
        #if canImport(AppKit)
        XCTAssertTrue(sawBold, "expected a bold run for <b>hi</b>")
        XCTAssertTrue(sawItalic, "expected an italic run for <i>there</i>")
        #endif
    }

    func testOverrideFontFamilyAppliesToAllRuns() {
        let s = makeSettings()
        s.readerOverrideFontFamily = true
        s.readerFontFamily = .mono
        let html = "<p><b>hi</b> <i>there</i></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        #if canImport(AppKit)
        var families: Set<String> = []
        n.enumerateAttribute(.font, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let f = value as? NSFont, let fam = f.familyName {
                families.insert(fam)
            }
        }
        XCTAssertFalse(families.isEmpty)
        for fam in families {
            // Menlo is the platform mono fallback. Any family
            // containing "Menlo" / "Mono" satisfies the override
            // (the importer may add weight suffixes).
            XCTAssertTrue(fam.lowercased().contains("menlo") || fam.lowercased().contains("mono"),
                          "family \(fam) is not the mono override")
        }
        #endif
    }

    func testOverrideForegroundColourBeatsCSS() {
        let s = makeSettings()
        s.readerOverrideColours = true
        s.readerTheme = .custom
        s.readerCustomColors = (background: (1, 1, 1), foreground: (0, 0, 1)) // blue
        let html = "<p><span style=\"color:red\">hello</span></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        #if canImport(AppKit)
        var foregrounds: [NSColor] = []
        n.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let c = value as? NSColor { foregrounds.append(c) }
        }
        XCTAssertFalse(foregrounds.isEmpty)
        for c in foregrounds {
            let srgb = c.usingColorSpace(.sRGB) ?? c
            // Blue ~ (0,0,1) — assert blue channel dominates.
            XCTAssertGreaterThan(srgb.blueComponent, 0.8, "expected override blue, got \(srgb)")
            XCTAssertLessThan(srgb.redComponent, 0.2, "red bleed-through from CSS")
        }
        #endif
    }

    func testRestoreOriginalReinstatesCSSColour() {
        let s = makeSettings()
        s.readerOverrideColours = true
        s.readerTheme = .custom
        s.readerCustomColors = (background: (1, 1, 1), foreground: (0, 0, 1))
        let html = "<p><span style=\"color:red\">hello</span></p>"

        s.restoreOriginal()

        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        #if canImport(AppKit)
        var sawRed = false
        n.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let c = (value as? NSColor)?.usingColorSpace(.sRGB),
               c.redComponent > 0.8, c.blueComponent < 0.2 {
                sawRed = true
            }
        }
        XCTAssertTrue(sawRed, "CSS red should survive after restoreOriginal()")
        #endif
    }

    func testBoldOverridePushesEveryRunBold() {
        let s = makeSettings()
        s.readerBoldOverride = true
        let html = "<p>plain prose, no markup</p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        #if canImport(AppKit)
        var allBold = true
        var ran = false
        n.enumerateAttribute(.font, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            ran = true
            if let f = value as? NSFont,
               !f.fontDescriptor.symbolicTraits.contains(.bold) {
                allBold = false
            }
        }
        XCTAssertTrue(ran)
        XCTAssertTrue(allBold, "every run must be bold under boldOverride")
        #endif
    }

    func testItalicSuppressStripsSlant() {
        let s = makeSettings()
        s.readerSuppressItalic = true
        let html = "<p><i>slanted text</i></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        #if canImport(AppKit)
        n.enumerateAttribute(.font, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let f = value as? NSFont {
                XCTAssertFalse(f.fontDescriptor.symbolicTraits.contains(.italic),
                               "italic survived suppression: \(f)")
            }
        }
        #endif
    }

    func testLetterSpacingAppliesAsKern() {
        let s = makeSettings()
        s.readerLetterSpacing = 2
        let html = "<p>hello</p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var sawKern = false
        n.enumerateAttribute(.kern, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let num = value as? NSNumber, abs(num.doubleValue - 2.0) < 0.01 {
                sawKern = true
            }
        }
        XCTAssertTrue(sawKern, "kern=2 should be applied to every run")
    }

    func testEmptyHtmlReturnsNilSoCallerFallsBackToPlain() {
        let s = makeSettings()
        XCTAssertNil(EpubHtmlRenderer.render(html: "", css: nil, settings: s))
        XCTAssertNil(EpubHtmlRenderer.render(html: "   \n  ", css: nil, settings: s))
    }
}
