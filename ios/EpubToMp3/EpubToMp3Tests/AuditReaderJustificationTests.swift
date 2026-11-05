import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class AuditReaderJustificationTests: XCTestCase {
    func testReopenedPreparedRendererRetainsJustifiedWordBreaking() async throws {
        let suite = "audit-warm-justification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreparedChapterArchiveStore(directory: root)
        let renderer = PreparedChapterRenderer(store: store)
        let settings = AppSettings(defaults: defaults)
        settings.readerOverrideTextAlignment = true
        settings.readerTextAlignment = .justified
        let body = "Esta é uma leitura de verificação do aplicativo. A biblioteca preserva os livros e a posição de leitura."
        let chapter = EbookFulltext.Chapter(index: 1, name: "Fixture", sourcePath: "chapter.xhtml", text: body,
            html: "<p>\(body)</p>", css: nil, charCount: body.count, segments: nil)
        let first = try XCTUnwrap(renderer.render(bookID: "warm-audit", chapterIndex: 0, chapter: chapter, settings: settings))
        await renderer.flush()
        let reopened = PreparedChapterRenderer(store: store)
        let restored = await reopened.restore(bookID: "warm-audit", chapterIndex: 0, chapter: chapter, settings: settings)
        let warm = try XCTUnwrap(restored)
        XCTAssertEqual(warm.string, first.string)
        for rendering in [first, warm] {
            let style = try XCTUnwrap(rendering.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.alignment, .justified)
            XCTAssertEqual(style.hyphenationFactor, 1)
            XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
        }
    }

    func testJustificationAllowsHyphenationWithoutChangingPublisherHeadingOrText() throws {
        let suite = "audit-justification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerOverrideTextAlignment = true
        settings.readerTextAlignment = .justified
        let body = "Extraordinariamente, a transformação preserva palavras e pontuação."
        let rendered = try XCTUnwrap(EpubHtmlRenderer.render(
            html: "<h1>Heading</h1><p>\(body)</p>", css: nil, settings: settings))
        let text = NSAttributedString(rendered)
        XCTAssertTrue(text.string.contains(body))
        let bodyRange = (text.string as NSString).range(of: body)
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: bodyRange.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.alignment, .justified)
        XCTAssertEqual(paragraph.hyphenationFactor, 1)
        let heading = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(heading.alignment, .center)
        XCTAssertEqual(settings.readerTextAlignment, .justified)
    }
}
