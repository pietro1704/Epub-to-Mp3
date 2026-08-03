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

    func testResolvesRelativeAndPercentEncodedImageResources() {
        let s = makeSettings()
        let resource = EbookFulltext.Chapter.Resource(
            href: "../images/cover%20art.png",
            mediaType: "image/png",
            dataBase64: "R0lGODlhAQABAIAAAAAAAP///yH5BAEKAAAALAAAAAABAAEAAAICTAEAOw=="
        )
        let html = "<p>text</p><img src=\"../images/cover%20art.png\"/>"
        guard let out = EpubHtmlRenderer.render(
            html: html, css: nil, settings: s, resources: [resource]
        ) else { return XCTFail("renderer returned nil") }
        let n = ns(out)
        var attachmentCount = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 1)
    }

    func testPreservesFragmentAndRelativeEPUBLinksForNativeRouting() {
        let s = makeSettings()
        let html = "<p><a href=\"#footnote_1\">*</a> <a href=\"chapter-2.xhtml#part\">Chapter Two</a></p>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var targets: [String] = []
        n.enumerateAttribute(.link, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if let url = value as? URL {
                targets.append(url.absoluteString)
            } else if let url = value as? NSURL {
                targets.append((url as URL).absoluteString)
            }
        }

        XCTAssertEqual(targets.count, 2)
        let decodedTargets = targets.compactMap { URLComponents(string: $0)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value
        }
        XCTAssertEqual(Set(decodedTargets), Set(["#footnote_1", "chapter-2.xhtml#part"]))
        XCTAssertTrue(targets.allSatisfy { $0.hasPrefix("epub-link://open?") })
    }

    func testLargeInlineImageIsDownsampled() throws {
        let s = makeSettings()
        let bigPNG = try Self.makeSolidPNGBase64(width: 2000, height: 2000)
        let html = "<p>text</p><img src=\"data:image/png;base64,\(bigPNG)\" alt=\"big\"/>"
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil for HTML with large inline image")
        }
        let n = ns(out)
        var maxEdge: CGFloat = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            #if canImport(AppKit)
            guard let att = value as? NSTextAttachment, let img = att.image else { return }
            // NSImage.size is in points; the cgImage carries true pixels.
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                maxEdge = max(maxEdge, CGFloat(max(cg.width, cg.height)))
            }
            #endif
        }
        #if canImport(AppKit)
        XCTAssertGreaterThan(maxEdge, 0, "expected a decoded attachment image")
        XCTAssertLessThanOrEqual(
            maxEdge, 1400,
            "inline image must be capped at 1400px; got \(maxEdge)px — full-res decode reintroduces the OOM device-freeze"
        )
        #endif
    }

    /// Build a base64-encoded solid-colour PNG of the given pixel size for
    /// exercising the inline-image downsample path.
    private static func makeSolidPNGBase64(width: Int, height: Int) throws -> String {
        #if canImport(AppKit)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("could not build PNG fixture")
        }
        return png.base64EncodedString()
        #else
        throw XCTSkip("PNG fixture only built on AppKit host")
        #endif
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

    func testAppliesReaderLineSpacingToRenderedParagraphs() {
        let settings = makeSettings()
        settings.readerLineSpacing = 12
        guard let output = EpubHtmlRenderer.render(
            html: "<p>First line.</p><p>Second line.</p>",
            css: nil,
            settings: settings
        ) else {
            return XCTFail("renderer returned nil")
        }

        var lineSpacings: [CGFloat] = []
        ns(output).enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: ns(output).length)
        ) { value, _, _ in
            if let style = value as? NSParagraphStyle {
                lineSpacings.append(style.lineSpacing)
            }
        }
        XCTAssertFalse(lineSpacings.isEmpty)
        XCTAssertTrue(lineSpacings.allSatisfy { abs($0 - 12) < 0.01 })
    }

    func testPreservesLordOfTheRingsParagraphIndentClasses() {
        let s = makeSettings()
        let html = """
        <p class="atx">The Shadow of the Past body paragraph.</p>
        <p class="atxq">A quoted paragraph.</p>
        <p class="atx-new">A newly separated paragraph.</p>
        <p class="p1">Front matter paragraph.</p>
        """
        let css = """
        .atx { text-indent: 20pt; margin-top: 0; margin-bottom: 0; }
        .atxq { text-indent: -20pt; margin-top: 0; margin-bottom: 0; }
        .atx-new { text-indent: 10pt; margin-top: 0; margin-bottom: 0; }
        .p1 { text-indent: 0; margin-top: 1em; margin-bottom: 1em; }
        """
        guard let out = EpubHtmlRenderer.render(html: html, css: css, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        var indents: [String: CGFloat] = [:]
        n.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: n.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let text = (n.string as NSString).substring(with: range)
            if text.contains("Shadow") { indents["atx"] = style.firstLineHeadIndent }
            if text.contains("quoted") { indents["atxq"] = style.firstLineHeadIndent }
            if text.contains("newly") { indents["atx-new"] = style.firstLineHeadIndent }
            if text.contains("Front") { indents["p1"] = style.firstLineHeadIndent }
        }
        XCTAssertEqual(indents["atx"] ?? .nan, CGFloat(20), accuracy: CGFloat(0.5))
        XCTAssertEqual(indents["atxq"] ?? .nan, CGFloat(-20), accuracy: CGFloat(0.5))
        XCTAssertEqual(indents["atx-new"] ?? .nan, CGFloat(10), accuracy: CGFloat(0.5))
        XCTAssertEqual(indents["p1"] ?? .nan, CGFloat(0), accuracy: CGFloat(0.5))
    }

    func testPreservesSemanticBlocksListsAndFigureCaptionText() {
        let s = makeSettings()
        let html = """
        <article>
          <h2>Chapter heading</h2>
          <p>Intro <strong>bold</strong> and <em>italic</em>.</p>
          <blockquote>Quoted paragraph.</blockquote>
          <figure><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEKAAAALAAAAAABAAEAAAICTAEAOw=="/><figcaption>Figure caption</figcaption></figure>
          <ol><li>First item</li><li>Second item</li></ol>
        </article>
        """
        guard let out = EpubHtmlRenderer.render(html: html, css: nil, settings: s) else {
            return XCTFail("renderer returned nil")
        }
        let n = ns(out)
        XCTAssertTrue(n.string.contains("Chapter heading"))
        XCTAssertTrue(n.string.contains("Quoted paragraph."))
        XCTAssertTrue(n.string.contains("Figure caption"))
        XCTAssertTrue(n.string.contains("First item"))
        XCTAssertTrue(n.string.contains("Second item"))
        var attachmentCount = 0
        n.enumerateAttribute(.attachment, in: NSRange(location: 0, length: n.length)) { value, _, _ in
            if value != nil { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 1)
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

    func testMarkupWithoutReadableTextReturnsNilSoCallerFallsBackToPlain() {
        let s = makeSettings()
        XCTAssertNil(EpubHtmlRenderer.render(
            html: "<html><head><style>body { color: red; }</style></head><body><br/></body></html>",
            css: nil,
            settings: s
        ))
    }

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
