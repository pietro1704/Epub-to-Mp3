import XCTest

/// Source-contract tests for the reader-1 slice: the on-device parser now
/// emits `html`/`css` per chapter, and both native reader controllers must
/// render it via `EpubHtmlRenderer`, falling back to plain `chapter.text`
/// only when `html` is absent (PDF, parse failure, or an old cached
/// payload). See `docs/reader-spec-comparison.md` P0 gap #1.
final class ReaderHtmlRenderingWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readSourceFileIfAvailable(
            at: root.appendingPathComponent("EpubToMp3/\(relativePath)")
        )
    }

    func testBookOpenScreenControllerRendersHtmlWithPlainTextFallback() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("EpubHtmlRenderer.render("))
        XCTAssertTrue(source.contains("textView.attributedText = NSAttributedString(rendered)"))
        XCTAssertTrue(source.contains("textView.text = fallbackText"))
    }

    func testMacReaderViewControllerRendersHtmlWithPlainTextFallback() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("EpubHtmlRenderer.render("))
        XCTAssertTrue(source.contains("textView.textStorage?.setAttributedString(NSAttributedString(rendered))"))
        XCTAssertTrue(source.contains("textView.string = chapter.text"))
    }

    func testLocalFulltextCacheDirectoryWasBumpedForHtmlCssPayloadChange() throws {
        let source = try source("Features/Offline/Services/LocalFulltextCache.swift")

        XCTAssertTrue(
            source.contains(#"appendingPathComponent("fulltext-v5""#),
            "Cache directory must be bumped so legacy cover/image-only payloads are re-parsed instead of served stale."
        )
    }
}
