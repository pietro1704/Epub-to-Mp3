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

    func testPreservesInlineDataURIImages() {
        let s = makeSettings()
        // Full valid 1x1 transparent GIF (header + image data + trailer) — a
        // truncated header-only payload is not decodable by UIImage/NSImage.
        let html = "<p>text</p><img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEKAAAALAAAAAABAAEAAAICTAEAOw==\" alt=\"pixel\"/>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for HTML with inline image")
        }
        let n = ns(out)
        var attachmentCount = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertGreaterThan(attachmentCount, 0,
            "inline data: URI images must survive HTML sanitisation so the importer can create attachments")
    }

    /// Regression: the EPUB's intentional centred alignment on a chapter
    /// title (Pinocchio's "Come andò che Maestro Ciliegia…") must survive
    /// the override pipeline — the user's body alignment choice only
    /// governs body paragraphs, not centred titles / headings.
    func testPreservesEpubCentredTitleAlignment() {
        let s = makeSettings()
        s.readerTextAlignment = .justified // body would otherwise justify everything
        let html = """
        <h1 style="text-align:center">Capitolo I</h1>
        <p>C'era una volta un pezzo di legno.</p>
        """
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var titleCentered = false
        var bodyNotCentered = false
        n.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: n.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let text = (n.string as NSString).substring(with: range)
            if text.contains("Capitolo"), style.alignment == .center { titleCentered = true }
            if text.contains("pezzo di legno"), style.alignment != .center { bodyNotCentered = true }
        }
        XCTAssertTrue(titleCentered, "EPUB-declared centred title alignment must be preserved")
        XCTAssertTrue(bodyNotCentered, "body paragraph must follow the user's alignment, not inherit center")
    }

    /// Content-agnostic guard: a BODY paragraph that merely inherited
    /// `text-align:center` from a wrapping container must NOT stay centred
    /// — only true headings (larger than the body font) keep centring.
    /// Detection keys on the EPUB's own font sizing, never on text length.
    func testCentredBodyParagraphIsNotPreserved() {
        let s = makeSettings()
        s.readerTextAlignment = .left
        // Whole body centred via a wrapper; the paragraph is body-sized.
        let html = """
        <div style="text-align:center">
        <p>This is an ordinary body paragraph that happens to sit inside a centred container and should not be rendered centred.</p>
        </div>
        """
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var anyCentered = false
        n.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, style.alignment == .center { anyCentered = true }
        }
        XCTAssertFalse(anyCentered, "a body-sized paragraph must not keep inherited center alignment")
    }

    /// Real-book regression: render the ACTUAL Pinocchio chapter HTML and
    /// assert the body paragraphs follow the user's alignment (the EPUB's
    /// own `p { text-align: justify }`) — NOT centred. The chapter title
    /// (`<h2>`) may be centred. The user reported "tudo centralizado";
    /// this pins the body to non-centre so a regression can't recur, using
    /// the book's real markup rather than a synthetic fixture.
    func testPinocchioRealChapterBodyIsNotCentred() {
        let s = makeSettings()
        s.readerTextAlignment = .justified
        guard let out = EpubHtmlRenderer.render(
            html: PinocchioFixture.chapter3HTML,
            css: PinocchioFixture.chapter3CSS,
            settings: s
        ) else { return XCTFail("renderer returned nil for real chapter") }
        let n = ns(out)

        var centredBodyChars = 0
        var totalBodyChars = 0
        n.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: n.length)) { value, range, _ in
            let text = (n.string as NSString).substring(with: range)
            // Body sentences from the real chapter (justify in the EPUB CSS).
            let isBody = text.contains("pezzo di legno")
                || text.contains("Non era un legno")
                || text.contains("piccoli lettori")
            guard isBody else { return }
            totalBodyChars += range.length
            if let style = value as? NSParagraphStyle, style.alignment == .center {
                centredBodyChars += range.length
            }
        }
        XCTAssertGreaterThan(totalBodyChars, 0, "fixture must contain recognisable body text")
        XCTAssertEqual(centredBodyChars, 0,
                       "real Pinocchio body paragraphs (text-align:justify) must never render centred")
    }

    /// Diagnostic: histogram of paragraph alignment across the WHOLE real
    /// chapter, so we can see exactly what the importer + override pipeline
    /// produce. Keeps the assertion loose (just prints) — used to pin down
    /// the "tudo centralizado" report.
    func testPinocchioAlignmentHistogram() {
        let s = makeSettings()
        s.readerTextAlignment = .justified
        guard let out = EpubHtmlRenderer.render(
            html: PinocchioFixture.chapter3HTML,
            css: PinocchioFixture.chapter3CSS,
            settings: s
        ) else { return XCTFail("nil") }
        let n = ns(out)
        var counts: [Int: Int] = [:]
        n.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: n.length)) { value, range, _ in
            let a = (value as? NSParagraphStyle)?.alignment.rawValue ?? -1
            counts[a, default: 0] += range.length
        }
        // alignment rawValues: left=0 right=1 center=2 justified=3 natural=4
        print("ALIGN histogram (rawValue:chars):", counts)
        XCTAssertFalse(counts.isEmpty)
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
        // Theme stays `.light`: the renderer force-overrides EPUB
        // colours for every theme except `.light`, so CSS-colour
        // survival is only defined under `.light`. This test verifies
        // the override-flag half — `restoreOriginal()` clearing
        // `readerOverrideColours` so the EPUB's own CSS wins.
        s.readerTheme = .light
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
