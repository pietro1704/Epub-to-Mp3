#if os(iOS)
import XCTest
@testable import EpubToMp3

/// Contract tests for scroll mode's single-chapter-at-a-time redesign
/// (2026-07-08). Previously scroll mode rendered the WHOLE book as one
/// `ScrollView`/`LazyVStack` — the `ForEach` iterated over every chapter's
/// identity even though the LazyVStack only materialised on-screen cells,
/// which was perceived as slow/heavy on large books. Scroll mode now shows
/// exactly ONE chapter (free scroll *within* it, same as before), and
/// crosses chapter boundaries only via an explicit action (edge tap /
/// footer button) — never a continuous multi-chapter scroll.
///
/// Paginated mode (`paginatedContent`) is untouched by this change.
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

    /// Scroll mode switches to the book-aware single-chapter path only when
    /// the host supplied more than one chapter — a single-chapter host
    /// (PlayerReaderView, nil bookChapters) keeps the plain per-chapter
    /// renderer untouched.
    func testScrollModeGatedOnBookChapters() throws {
        let src = try readerSource()
        XCTAssertTrue(src.contains("if let bookChapters, bookChapters.count > 1"),
                      "Book-aware scroll must be gated on a multi-chapter bookChapters array")
        XCTAssertTrue(src.contains("singleChapterScroll(chapters: bookChapters)"))
    }

    /// The redesign must NOT reintroduce a LazyVStack/ForEach over every
    /// chapter in `singleChapterScroll` — that was the whole-book render
    /// this change eliminates. `scrollingContent` (the single-chapter
    /// TextKit view) is reused instead.
    func testSingleChapterScrollRendersOneChapterOnly() throws {
        let src = try readerSource()
        guard let range = src.range(of: "private func singleChapterScroll"),
              let endRange = src.range(of: "\n    private func advanceChapter", range: range.upperBound..<src.endIndex)
        else {
            return XCTFail("singleChapterScroll function body not found")
        }
        let body = String(src[range.upperBound..<endRange.lowerBound])
        XCTAssertTrue(body.contains("scrollingContent"),
                      "singleChapterScroll must reuse the existing single-chapter renderer")
        XCTAssertFalse(body.contains("LazyVStack"),
                       "singleChapterScroll must not render every chapter in a LazyVStack")
        XCTAssertFalse(body.contains("ForEach(chapters)"),
                       "singleChapterScroll must not iterate the whole chapter list into the view tree")
    }

    /// Chapter-boundary crossing must be an explicit action (edge tap or
    /// footer button) reusing the SAME `onAdvanceChapter`/`onPreviousChapter`
    /// contract paginated mode already uses — not a continuous scrollTo.
    func testChapterCrossingIsExplicitAction() throws {
        let src = try readerSource()
        XCTAssertTrue(src.contains("private func advanceChapter(chapters:"))
        XCTAssertTrue(src.contains("private func retreatChapter(chapters:"))
        XCTAssertTrue(src.contains("guard onAdvanceChapter?() == true else { return }"))
        XCTAssertTrue(src.contains("guard onPreviousChapter?() == true else { return }"))
    }

    /// Neighbour chapters must be pre-rendered into `BookChapterRenderCache`
    /// ahead of the user reaching them, so the explicit chapter-crossing
    /// action feels instantaneous instead of paying the HTML-parse cost
    /// synchronously on arrival.
    func testPrefetchesNeighbourChapters() throws {
        let src = try readerSource()
        XCTAssertTrue(src.contains("private func prefetchNeighbours"))
        XCTAssertTrue(src.contains("[idx - 1, idx + 1]"),
                      "prefetch must target both the previous and next chapter")
        XCTAssertTrue(src.contains("BookChapterRenderCache.store(rendered, for: key)"))
    }

    /// InstantReaderView (the host that owns the full chapter list) still
    /// wires `bookChapters` + the scroll-mirror callback; the mirror still
    /// guards against a feedback loop when the index is unchanged.
    func testInstantReaderWiresBookChapters() throws {
        let src = try instantReaderSource()
        XCTAssertTrue(src.contains("bookChapters: fulltext.chapters"),
                      "InstantReaderView must pass the full chapter list so scroll mode can prefetch neighbours")
        XCTAssertTrue(src.contains("onScrolledToChapter: { mirrorScrolledChapter($0) }"))
        XCTAssertTrue(src.contains("guard zeroBasedIndex != currentChapterIndex"),
                      "mirrorScrolledChapter must no-op when the index is unchanged to avoid a scroll/onChange loop")
    }

    /// The book is identified per-chapter via the zero-based EPUB axis used
    /// throughout scroll-mode chapter crossing and prefetch indexing.
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
