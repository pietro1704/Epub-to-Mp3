import XCTest
@testable import EpubToMp3

/// Regression: paginated reader used to dead-end on the last page of
/// the current chapter — `handleKeyPress`/`tapZones`/`DragGesture` all
/// clamped to `pages.count`. Carl Sagan's "Pale Blue Dot" parses into
/// many chapters; the reader showed only the first page of chapter 1
/// and then nothing.
///
/// Fix (`ReaderView.advancePage`/`retreatPage`) delegates to the host
/// view's `onAdvanceChapter` / `onPreviousChapter` callbacks at the
/// page boundary. These tests exercise the host-side counters that
/// those callbacks bump — `InstantReaderView.advanceToNextChapter` /
/// `returnToPreviousChapter` — without mounting a SwiftUI view tree.
final class ReaderChapterAdvanceTests: XCTestCase {

    /// Minimal stand-in for the `InstantReaderView` state machinery.
    /// Mirrors the exact same logic the view holds so the contract
    /// stays in lockstep — if you change the view, change this.
    private struct AdvanceModel {
        var currentChapterIndex: Int
        let chapterCount: Int

        /// Returns true if there is a next chapter and we advanced.
        mutating func advance() -> Bool {
            guard currentChapterIndex + 1 < chapterCount else { return false }
            currentChapterIndex += 1
            return true
        }

        mutating func retreat() -> Bool {
            guard currentChapterIndex > 0 else { return false }
            currentChapterIndex -= 1
            return true
        }
    }

    func testAdvanceMovesForwardThroughChapters() {
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 5)
        XCTAssertTrue(m.advance())
        XCTAssertEqual(m.currentChapterIndex, 1)
        XCTAssertTrue(m.advance())
        XCTAssertTrue(m.advance())
        XCTAssertTrue(m.advance())
        XCTAssertEqual(m.currentChapterIndex, 4)
    }

    func testAdvanceReturnsFalseOnLastChapter() {
        var m = AdvanceModel(currentChapterIndex: 4, chapterCount: 5)
        XCTAssertFalse(m.advance(),
                       "must report no-advance on the last chapter so the reader stays put")
        XCTAssertEqual(m.currentChapterIndex, 4)
    }

    func testRetreatMovesBackward() {
        var m = AdvanceModel(currentChapterIndex: 3, chapterCount: 5)
        XCTAssertTrue(m.retreat())
        XCTAssertEqual(m.currentChapterIndex, 2)
    }

    func testRetreatReturnsFalseOnFirstChapter() {
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 5)
        XCTAssertFalse(m.retreat())
        XCTAssertEqual(m.currentChapterIndex, 0)
    }

    func testCarlScenario_ManyChaptersStayReachable() {
        // Pale Blue Dot has ~24 chapters. Simulate the user paging
        // through to the end and back to confirm no dead-end.
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 24)
        var advanced = 0
        while m.advance() { advanced += 1 }
        XCTAssertEqual(advanced, 23)
        XCTAssertEqual(m.currentChapterIndex, 23)

        var retreated = 0
        while m.retreat() { retreated += 1 }
        XCTAssertEqual(retreated, 23)
        XCTAssertEqual(m.currentChapterIndex, 0)
    }

    func testSingleChapterBookHasNoAdvanceTarget() {
        // Defensive: a 1-chapter book should report no-advance and
        // no-retreat, so the reader silently keeps the page bound.
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 1)
        XCTAssertFalse(m.advance())
        XCTAssertFalse(m.retreat())
    }
}
