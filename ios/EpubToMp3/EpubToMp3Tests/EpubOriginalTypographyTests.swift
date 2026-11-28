import XCTest
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

extension EpubHtmlRendererTests {
    @MainActor
    func testReferenceFamilyKeepsPublisherSizeAndInlineEmphasis() throws {
        let settings = makeSettings()
        settings.readerFontFamily = .newYork
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<p style='font-size:18pt'><b>ação</b> <i>coração</i></p>", css: nil, textSettings: ReaderTextSettings(settings: settings))))
        for (text, italic) in [("ação", false), ("coração", true)] {
            let location = (rendered.string as NSString).range(of: text).location
            let font = try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont)
            XCTAssertEqual(font.pointSize, 18, accuracy: 0.5)
            #if canImport(UIKit)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(italic ? .traitItalic : .traitBold))
            #else
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(italic ? .italic : .bold))
            #endif
        }
    }

    @MainActor
    func testCssAbsoluteUnitsRenderAsNativePointsAndReaderOverridesStillWin() throws {
        let settings = makeSettings()
        let html = """
        <p style='font-size:24px'>Pixels.</p><p style='font-size:0.25in'>Inches.</p>\
        <p style='font-size:1.5em'>Relative.</p><p>Default.</p>
        """
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: html, css: nil, textSettings: ReaderTextSettings(settings: settings))))
        func size(_ text: String, in string: NSAttributedString) throws -> CGFloat {
            let location = (string.string as NSString).range(of: text).location
            return try XCTUnwrap(string.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont).pointSize
        }
        XCTAssertEqual(try size("Pixels", in: rendered), 18, accuracy: 0.5, "A CSS px is 0.75 point.")
        XCTAssertEqual(try size("Inches", in: rendered), 18, accuracy: 0.5)
        XCTAssertEqual(try size("Relative", in: rendered), try size("Default", in: rendered) * 1.5, accuracy: 0.5)

        settings.readerOverrideFontSize = true
        settings.readerLineSpacing = 9
        let overridden = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<p style='font-size:18pt;line-height:30pt'>Override.</p>", css: nil, textSettings: ReaderTextSettings(settings: settings))))
        #if canImport(UIKit)
        let expected = UIFontMetrics(forTextStyle: .body).scaledValue(for: settings.readerPointSize)
        #else
        let expected = settings.readerPointSize
        #endif
        XCTAssertEqual(try size("Override", in: overridden), expected, accuracy: 0.5)
        let style = try XCTUnwrap(overridden.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(settings.readerOverrideLineSpacing)
        XCTAssertEqual(style.lineSpacing, 9)
    }

    func testImporterLengthRewriteKeepsUrlsStringsCommentsAndMediaQueries() {
        XCTAssertEqual(
            EpubCssLengths.importerCSS(
                "@media (min-width:600px) { p {margin:-20pt 12px .5in} } /* 12pt */ h1{font:'A 12pt' 1pc;background:url(a12pt.png)}"),
            "@media (min-width:600px) { p {margin:-20px 9px 36px} } /* 12pt */ h1{font:'A 12pt' 12px;background:url(a12pt.png)}")
        XCTAssertEqual(EpubCssLengths.importerCSS(".w12px{width:1.5em;height:10%}"), ".w12px{width:1.5em;height:10%}")
        XCTAssertEqual(
            EpubCssLengths.importerCSS(#"img[width=12px]{background:url("cover(1).png")} p{font-size:12pt;width:99999999999999999999px}"#),
            #"img[width=12px]{background:url("cover(1).png")} p{font-size:12px;width:99999999999999999999px}"#)
        XCTAssertEqual(
            EpubCssLengths.importerHTML("<p class='x12pt' style=\"font-size:18pt;font-family:'Georgia'\">12pt</p>"),
            "<p class='x12pt' style=\"font-size:18px;font-family:'Georgia'\">12pt</p>")
        XCTAssertEqual(
            EpubCssLengths.importerHTML("<pre>&lt;p style=\"margin:12pt\"&gt;</pre><p style=font-size:18pt>x</p>"),
            "<pre>&lt;p style=\"margin:12pt\"&gt;</pre><p style=font-size:18px>x</p>",
            "Text content is never rewritten; unquoted legacy style attributes are.")
    }

    @MainActor
    func testParagraphGeometryUsesTheSameAbsoluteUnitMapping() throws {
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<p style='margin-bottom:0.25in;text-indent:16px'>Inches.</p>", css: nil, textSettings: ReaderTextSettings(settings: makeSettings()))))
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 18, accuracy: 0.5)
        XCTAssertEqual(style.firstLineHeadIndent, 12, accuracy: 0.5)
    }

    @MainActor
    func testNamedFontSelectionPersistsAndOriginalClearsOnlyFamilyOverride() throws {
        let suite = "font-choice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerOverrideFontSize = true
        settings.readerFontFamily = .newYork
        XCTAssertTrue(settings.readerOverrideFontFamily)
        XCTAssertEqual(AppSettings(defaults: defaults).selectedReaderFontFamily, .newYork)
        settings.readerFontFamily = .original
        XCTAssertFalse(settings.readerOverrideFontFamily)
        XCTAssertTrue(settings.readerOverrideFontSize)
        XCTAssertEqual(AppSettings(defaults: defaults).selectedReaderFontFamily, .original)
    }

    @MainActor
    func testOriginalPreservesPublisherFontSizesAlignmentAndParagraphGeometry() throws {
        let settings = makeSettings()
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: """
        <html><head><style>.poem {text-align:right;font-family:Georgia;font-size:18pt}
        h1 {font-size:48pt} p {text-indent:35pt;margin-top:30pt;margin-bottom:28pt}</style></head>
        <body class='poem'><h1>Title</h1><p>Publisher verse.</p></body></html>
        """, css: nil, textSettings: ReaderTextSettings(settings: settings))))
        let body = (rendered.string as NSString).range(of: "Publisher verse").location
        let title = (rendered.string as NSString).range(of: "Title").location
        let font = try XCTUnwrap(rendered.attribute(.font, at: body, effectiveRange: nil) as? PlatformFont)
        let titleFont = try XCTUnwrap(rendered.attribute(.font, at: title, effectiveRange: nil) as? PlatformFont)
        #if canImport(UIKit)
        XCTAssertTrue(font.familyName.contains("Georgia"))
        #else
        XCTAssertTrue(font.familyName?.contains("Georgia") == true)
        #endif
        XCTAssertEqual(font.pointSize, 18, accuracy: 0.5)
        XCTAssertEqual(titleFont.pointSize, 48, accuracy: 0.5)
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .right)
        XCTAssertEqual(style.firstLineHeadIndent, 35, accuracy: 0.5)
        XCTAssertEqual(style.paragraphSpacingBefore, 30, accuracy: 0.5)
        XCTAssertEqual(style.paragraphSpacing, 28, accuracy: 0.5)
        XCTAssertFalse(settings.readerOverrideTextAlignment)
        XCTAssertFalse(settings.readerOverrideLineSpacing)
    }

    @MainActor
    func testExplicitControlsOverrideAndOriginalResetRestoresPublisherParagraphs() throws {
        let settings = makeSettings()
        let html = "<p style='text-align:right;font-size:18pt'>Publisher verse.</p>"
        settings.readerTextAlignment = .left
        settings.readerLineSpacing = 12
        let overridden = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: html, css: nil, textSettings: ReaderTextSettings(settings: settings))))
        let selected = try XCTUnwrap(overridden.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(selected.alignment, .left)
        XCTAssertEqual(selected.lineSpacing, 12)
        settings.restoreOriginal()
        let original = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: html, css: nil, textSettings: ReaderTextSettings(settings: settings))))
        let restored = try XCTUnwrap(original.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(restored.alignment, .right)
        XCTAssertFalse(settings.readerOverrideLineSpacing)
    }

    @MainActor
    func testFontFaceAliasUsesAnAvailableNativeFontWithoutCopyingFontAssets() throws {
        let installed = CTFontCreateWithName("Georgia" as CFString, 18, nil)
        guard let url = CTFontCopyAttribute(installed, kCTFontURLAttribute) as? URL,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("This runtime does not expose a readable installed font resource.")
        }
        let css = "@font-face {font-family:PublisherAlias;src:url('\(url.lastPathComponent)')} p {font-family:PublisherAlias}"
        let aliases = EpubFontManager.familyAliases(css: css, directory: url.deletingLastPathComponent())
        XCTAssertEqual(aliases["publisheralias"], CTFontCopyFamilyName(installed) as String)
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: "<p>Publisher text.</p>", css: css,
            textSettings: ReaderTextSettings(settings: makeSettings()), fontDirectoryURL: url.deletingLastPathComponent())))
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #if canImport(UIKit)
        XCTAssertEqual(font.familyName, CTFontCopyFamilyName(installed) as String)
        #else
        XCTAssertEqual(font.familyName, CTFontCopyFamilyName(installed) as String)
        #endif
    }

    @MainActor
    func testChoosingASizeResizesHtmlTextAndKeepsTheHeadingHierarchy() throws {
        let settings = makeSettings()
        XCTAssertFalse(settings.readerOverrideFontSize, "A fresh install shows the publisher sizes.")
        let html = "<h1 style='font-size:48pt'>Title</h1><h3 style='font-size:20pt'>Section</h3>"
            + String(repeating: "<p style='font-size:12pt'>Body paragraph.</p>", count: 4)
        for step in [3, 6, 1] {
            settings.readerFontSize = step
            XCTAssertTrue(settings.readerOverrideFontSize, "Choosing a size applies it to the book.")
            let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
                html: html, css: nil, textSettings: ReaderTextSettings(settings: settings))))
            let body = chosenPointSize(settings)
            XCTAssertEqual(try pointSize("Body", in: rendered), body, accuracy: 0.5)
            // Flutter's cappedHeadingSize: min(body + 6, body * 1.5).
            XCTAssertEqual(try pointSize("Title", in: rendered), min(body + 6, body * 1.5), accuracy: 0.5)
            XCTAssertEqual(try pointSize("Section", in: rendered), min(body + 6, body * 1.5), accuracy: 0.5)
        }
    }

    @MainActor
    func testOriginalTypographyAfterASizeChoiceRestoresThePublisherSizes() throws {
        let settings = makeSettings()
        settings.readerFontSize = 6
        settings.restoreOriginal()
        XCTAssertFalse(settings.readerOverrideFontSize)
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<h1 style='font-size:48pt'>Title</h1><p style='font-size:12pt'>Body.</p>", css: nil,
            textSettings: ReaderTextSettings(settings: settings))))
        let title = try pointSize("Title", in: rendered)
        XCTAssertGreaterThan(title, try pointSize("Body", in: rendered) * 3)
    }

    @MainActor
    func testSavedSizeOverrideSurvivesTheUpdate() throws {
        // (saved size, saved override, expected override); the same rule as Flutter's readerOverrideFontSize.
        let cases: [(Int?, Bool?, Bool)] = [(5, true, true), (5, nil, true), (5, false, false), (nil, nil, false)]
        for (size, override, expected) in cases {
            let suite = "font-size-migration-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let size { defaults.set(size, forKey: "readerFontSize") }
            if let override { defaults.set(override, forKey: "readerOverrideFontSize") }
            let label = "size \(String(describing: size)), override \(String(describing: override))"
            XCTAssertEqual(AppSettings(defaults: defaults).readerOverrideFontSize, expected, label)
            // Loading is not a choice: a second launch reads the same state.
            XCTAssertEqual(AppSettings(defaults: defaults).readerOverrideFontSize, expected, label)
        }
    }

    @MainActor
    private func chosenPointSize(_ settings: AppSettings) -> CGFloat {
        #if canImport(UIKit)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: settings.readerPointSize)
        #else
        return settings.readerPointSize
        #endif
    }

    private func pointSize(_ text: String, in string: NSAttributedString) throws -> CGFloat {
        let location = (string.string as NSString).range(of: text).location
        return try XCTUnwrap(string.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont).pointSize
    }
}
