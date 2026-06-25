#if os(iOS)
import XCTest
@testable import EpubToMp3

/// Contract tests for the continuous full-book scroll mode added to the
/// reader. The mode renders the WHOLE book as one `ScrollView`/`LazyVStack`
/// (one `BookChapterCell` per chapter) instead of a single chapter, and is
/// gated on the host passing `bookChapters`.
@MainActor
final class ContinuousBookScrollTests: XCTestCase {

    private func readerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Views/ReaderView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func instantReaderSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Views/InstantReaderView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Scroll mode switches to the whole-book path only when the host
    /// supplied more than one chapter — a single-chapter host
    /// (PlayerReaderView, nil bookChapters) keeps the per-chapter renderer.
    func testContinuousScrollGatedOnBookChapters() throws {
        let src = try readerSource()
        XCTAssertTrue(src.contains("if let bookChapters, bookChapters.count > 1"),
                      "Continuous scroll must be gated on a multi-chapter bookChapters array")
        XCTAssertTrue(src.contains("continuousBookScroll(chapters: bookChapters)"))
        XCTAssertTrue(src.contains("LazyVStack"),
                      "The whole book must render in a LazyVStack so off-screen chapters aren't all built up front")
        XCTAssertTrue(src.contains("ForEach(chapters)"))
    }

    /// InstantReaderView (the host that owns the full chapter list) wires
    /// the whole-book scroll; the mirror guards against a feedback loop.
    func testInstantReaderWiresBookChapters() throws {
        let src = try instantReaderSource()
        XCTAssertTrue(src.contains("bookChapters: fulltext.chapters"),
                      "InstantReaderView must pass the full chapter list for continuous scroll")
        XCTAssertTrue(src.contains("onScrolledToChapter: { mirrorScrolledChapter($0) }"))
        XCTAssertTrue(src.contains("guard zeroBasedIndex != currentChapterIndex"),
                      "mirrorScrolledChapter must no-op when the index is unchanged to avoid a scroll/onChange loop")
    }

    /// The book is identified per-chapter via the zero-based EPUB axis used
    /// by the scroll cell `.id(...)` and the auto-follow scrollTo.
    func testChapterZeroBasedAxisMatchesCellId() {
        let ch = EbookFulltext.Chapter(
            index: 5, name: "Cap V", text: "x", html: nil, css: nil,
            charCount: 1, segments: nil
        )
        XCTAssertEqual(ch.zeroBasedEpubIndex, 4)
    }

    /// The plain-text fallback the cell uses collapses hard wraps and
    /// strips the leading EPUB artifact, matching the paginated renderer.
    func testCellPlainFallbackNormalisation() {
        // The cell applies stripLeadingArtifact(collapseHardWraps(text)),
        // the same order as Chapter.splitSentences. A standalone artifact
        // line followed by a paragraph break survives collapse (as \n\n)
        // and is then stripped.
        let raw = "c34\n\nLine one\nstill one\n\nLine two"
        let collapsed = EbookFulltext.Chapter.collapseHardWraps(raw)
        let stripped = EbookFulltext.Chapter.stripLeadingArtifact(collapsed)
        XCTAssertFalse(stripped.hasPrefix("c34"), "leading artifact code must be stripped")
        XCTAssertTrue(stripped.contains("Line one still one"), "hard wraps within a paragraph collapse to spaces")
        XCTAssertTrue(stripped.contains("Line two"), "later paragraphs survive")
    }
}
#endif
