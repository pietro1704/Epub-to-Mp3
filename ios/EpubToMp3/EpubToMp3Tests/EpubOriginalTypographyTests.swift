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
    func testOriginalPreservesPublisherFontSizesAlignmentAndParagraphGeometry() throws {
        let settings = makeSettings()
        let rendered = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: """
        <html><head><style>.poem {text-align:right;font-family:Georgia;font-size:18pt}
        h1 {font-size:48pt} p {text-indent:35pt;margin-top:30pt;margin-bottom:28pt}</style></head>
        <body class='poem'><h1>Title</h1><p>Publisher verse.</p></body></html>
        """, css: nil, settings: settings)))
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
        let overridden = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: html, css: nil, settings: settings)))
        let selected = try XCTUnwrap(overridden.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(selected.alignment, .left)
        XCTAssertEqual(selected.lineSpacing, 12)
        settings.restoreOriginal()
        let original = ns(try XCTUnwrap(EpubHtmlRenderer.render(html: html, css: nil, settings: settings)))
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
            settings: makeSettings(), fontDirectoryURL: url.deletingLastPathComponent())))
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        #if canImport(UIKit)
        XCTAssertEqual(font.familyName, CTFontCopyFamilyName(installed) as String)
        #else
        XCTAssertEqual(font.familyName, CTFontCopyFamilyName(installed) as String)
        #endif
    }
}
