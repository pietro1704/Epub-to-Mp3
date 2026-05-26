import XCTest
@testable import EpubToMp3

/// Pins the 1-based ↔ 0-based conversion behaviour `InstantReaderView`
/// relies on when the search overlay (and any other call site that
/// receives a `FulltextChapter`) hands off into the EPUB-axis state.
///
/// Pre-slice-21 the search overlay assignment skipped the conversion,
/// so the player and widget drifted by one chapter after every search
/// jump. The fix is a one-liner — this test exists to keep it from
/// re-drifting.
final class EbookFulltextChapterAxisTests: XCTestCase {

    func testZeroBasedEpubIndexSubtractsOneFromBackendValue() {
        let ch = EbookFulltext.Chapter(
            index: 3,
            name: "Chapter Three",
            text: "lorem ipsum",
            html: nil,
            css: nil,
            charCount: 11,
            segments: nil
        )
        XCTAssertEqual(ch.zeroBasedEpubIndex, 2,
            "FulltextChapter.index is 1-based on the wire; zero-based axis is `index - 1`")
    }

    func testZeroBasedEpubIndexClampsNonPositiveToZero() {
        // Defensive: backend should never emit index <= 0 in practice,
        // but a malformed response must not produce a negative cursor.
        let ch = EbookFulltext.Chapter(
            index: 0, name: nil, text: "x",
            html: nil, css: nil, charCount: 1, segments: nil
        )
        XCTAssertEqual(ch.zeroBasedEpubIndex, 0)

        let chNegative = EbookFulltext.Chapter(
            index: -5, name: nil, text: "x",
            html: nil, css: nil, charCount: 1, segments: nil
        )
        XCTAssertEqual(chNegative.zeroBasedEpubIndex, 0)
    }
}
