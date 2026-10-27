#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderSearchViewportTests: XCTestCase {
    private func fixture() -> (ReaderTextViewport, UITextView, UIScrollView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        let scroll = UIScrollView(frame: host.bounds)
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 9000))
        text.isScrollEnabled = false
        text.attributedText = NSAttributedString(
            string: Array(repeating: "Leitura, ação e páginas.\n", count: 200).joined() + "TARGET",
            attributes: [.font: UIFont.systemFont(ofSize: 20)])
        host.addSubview(scroll)
        scroll.addSubview(text)
        let viewport = ReaderTextViewport(textView: text, scrollView: scroll, hostView: host,
            pageIndicator: UILabel(), overflowGuard: UIView(), underflowGuard: UIView(),
            paginatedHeight: text.heightAnchor.constraint(equalToConstant: 9000),
            scrollingHeight: text.heightAnchor.constraint(equalToConstant: 9000))
        return (viewport, text, scroll)
    }

    func testSearchMovesTheOuterViewportToACanonicalUnclippedPage() throws {
        let (viewport, text, scroll) = fixture()
        let facts = try XCTUnwrap(viewport.presentPaginated(preservingRawOffset: nil))
        scroll.contentSize = CGSize(width: 320, height: facts.contentHeight)
        let range = try XCTUnwrap(ReaderBookSearch.firstRange(query: "target", in: text.attributedText.string))
        XCTAssertTrue(viewport.reveal(range))
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertEqual(text.contentOffset, .zero)
        XCTAssertTrue(facts.canonicalPageOffsets.contains(scroll.contentOffset.y))
        XCTAssertEqual(facts.layoutResult?.clippingReport(at: scroll.contentOffset.y).clippedLineCount, 0)
        XCTAssertEqual(text.selectedRange, range)
    }

    func testInvalidSearchRangeCannotMoveTheReader() {
        let (viewport, text, scroll) = fixture()
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                      NSRange(location: text.textStorage.length, length: 1), NSRange(location: 0, length: 0)] {
            XCTAssertFalse(viewport.reveal(range))
            XCTAssertEqual(scroll.contentOffset, .zero)
        }
    }

    func testSearchSelectsTheRenderedRangeInsteadOfTheRawSourceOffset() async throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Target")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        harness.composition.textView.attributedText = NSAttributedString(string: "📖 Heading\nTarget")
        harness.annotations.performSearch(query: "target")
        await harness.annotations.waitForSearchCompletion()
        XCTAssertEqual(harness.composition.textView.selectedRange, NSRange(location: 11, length: 6))
    }

    func testMissingQueryPreservesChapterAndRawOffset() async throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Current text")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        let origin = harness.composition.scrollView.contentOffset
        harness.annotations.performSearch(query: "absent")
        await harness.annotations.waitForSearchCompletion()
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.composition.scrollView.contentOffset, origin)
        XCTAssertEqual(harness.persisted, 0)
        XCTAssertEqual(harness.renderedIndices, [0])
    }

    func testCancelledQueryCannotNavigateOrPersistLater() async throws {
        let harness = try NativeReaderTestHarness(chapters: [
            NativeReaderTestHarness.chapter("Current"), NativeReaderTestHarness.chapter("Target", index: 2)])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        harness.annotations.performSearch(query: "target")
        harness.annotations.cancelSearch()
        await harness.annotations.waitForSearchCompletion()
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertEqual(harness.persisted, 0)
        XCTAssertEqual(harness.renderedIndices, [0])
    }

    func testBookReplacementRejectsTheCompletedQuery() async throws {
        let harness = try NativeReaderTestHarness(chapters: [
            NativeReaderTestHarness.chapter("Current"), NativeReaderTestHarness.chapter("Target", index: 2)])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        var current = true
        var effects = 0
        let search = ReaderSearchPresentation(document: harness.document, composition: harness.composition,
            persist: { effects += 1 }, showChapter: { _ in effects += 1 }, present: { _ in effects += 1 },
            isCurrentBook: { current })
        search.performSearch(query: "target")
        current = false
        await search.waitForCompletion()
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(harness.document.selectedChapter, 0)
    }
}
#endif
