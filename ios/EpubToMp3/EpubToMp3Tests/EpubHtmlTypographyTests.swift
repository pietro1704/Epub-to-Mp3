import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
@testable import EpubToMp3

extension EpubHtmlRendererTests {
    @MainActor
    func testThemeOverrideUsesSurfacePaletteAndClearsPublisherBackgrounds() throws {
        let settings = makeSettings()
        for theme in [ReaderTheme.sepia, .parchment, .paper, .dark, .black] {
            settings.readerTheme = theme
            #if canImport(UIKit)
            let expected = theme.previewColors.foreground
            #else
            let expected = theme.macOSColors.foreground
            #endif
            let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
                html: "<p><span style='color:red;background-color:yellow'>Body</span></p>",
                css: nil, settings: settings)))
            let location = (rendered.string as NSString).range(of: "Body").location
            let actual = try XCTUnwrap(rendered.attribute(.foregroundColor, at: location, effectiveRange: nil) as? PlatformColor)
            for (a, e) in zip(rgba(actual), rgba(expected)) {
                XCTAssertEqual(a, e, accuracy: 0.005, "\(theme.rawValue) must share its surface palette")
            }
            XCTAssertNil(rendered.attribute(.backgroundColor, at: location, effectiveRange: nil),
                         "The reader surface owns the background; publisher runs must not paint rectangles")
        }
    }

    @MainActor
    func testDarkOverridePreservesLinkAndTypographyWithDistinctReadableLinkColor() throws {
        let settings = makeSettings()
        settings.readerTheme = .dark
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<p><b>Body</b> <a href='#note'><i>Reference</i></a></p>",
            css: nil, settings: settings)))
        let body = (rendered.string as NSString).range(of: "Body").location
        let link = (rendered.string as NSString).range(of: "Reference").location
        XCTAssertNotNil(rendered.attribute(.link, at: link, effectiveRange: nil))
        let bodyColor = try XCTUnwrap(rendered.attribute(.foregroundColor, at: body, effectiveRange: nil) as? PlatformColor)
        let linkColor = try XCTUnwrap(rendered.attribute(.foregroundColor, at: link, effectiveRange: nil) as? PlatformColor)
        XCTAssertNotEqual(rgba(bodyColor), rgba(linkColor), "Overriding colors must keep links distinguishable")
        let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: body, effectiveRange: nil) as? PlatformFont)
        let linkFont = try XCTUnwrap(rendered.attribute(.font, at: link, effectiveRange: nil) as? PlatformFont)
        #if canImport(UIKit)
        XCTAssertTrue(bodyFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(linkFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #else
        XCTAssertTrue(bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(linkFont.fontDescriptor.symbolicTraits.contains(.italic))
        #endif
    }

    @MainActor
    func testLightWithoutOverridePreservesPublisherBodyAndLinkColors() throws {
        let settings = makeSettings()
        settings.readerTheme = .light
        settings.readerOverrideColours = false
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<p><span style='color:#ff0000'>Body</span> <a href='#note' style='color:#008000'>Reference</a></p>",
            css: nil, settings: settings)))
        let body = (rendered.string as NSString).range(of: "Body").location
        let link = (rendered.string as NSString).range(of: "Reference").location
        let bodyColor = rgba(try XCTUnwrap(rendered.attribute(.foregroundColor, at: body, effectiveRange: nil) as? PlatformColor))
        let linkColor = rgba(try XCTUnwrap(rendered.attribute(.foregroundColor, at: link, effectiveRange: nil) as? PlatformColor))
        XCTAssertGreaterThan(bodyColor[0], 0.9)
        XCTAssertLessThan(bodyColor[1], 0.1)
        XCTAssertGreaterThan(linkColor[1], 0.4)
        XCTAssertLessThan(linkColor[0], 0.1)
        XCTAssertNotNil(rendered.attribute(.link, at: link, effectiveRange: nil))
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

}
