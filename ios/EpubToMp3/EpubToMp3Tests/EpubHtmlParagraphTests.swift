import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

extension EpubHtmlRendererTests {
    /// Regression: the EPUB's intentional centred alignment on a chapter
    /// title (Pinocchio's "Come andò che Maestro Ciliegia…") must survive
    /// the override pipeline — the user's body alignment choice only
    /// governs body paragraphs, not centred titles / headings.
    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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
    @MainActor
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
    @MainActor
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
    @MainActor
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

}
