import XCTest
@testable import EpubToMp3

#if os(iOS)
final class ReaderTapActionTests: XCTestCase {
    private let readerBounds = CGRect(x: 0, y: 0, width: 390, height: 760)

    func testCenterTapAlwaysTogglesReaderChrome() {
        XCTAssertEqual(
            ReaderTapAction.resolve(
                point: CGPoint(x: 195, y: 380),
                in: readerBounds,
                isPaginated: true
            ),
            .toggleChrome
        )
    }

    func testSideTapsTurnOnlyPaginatedPages() {
        XCTAssertEqual(
            ReaderTapAction.resolve(
                point: CGPoint(x: 20, y: 380),
                in: readerBounds,
                isPaginated: true
            ),
            .turnPage(forward: false)
        )
        XCTAssertEqual(
            ReaderTapAction.resolve(
                point: CGPoint(x: 370, y: 380),
                in: readerBounds,
                isPaginated: true
            ),
            .turnPage(forward: true)
        )
        XCTAssertEqual(
            ReaderTapAction.resolve(
                point: CGPoint(x: 20, y: 380),
                in: readerBounds,
                isPaginated: false
            ),
            .none
        )
    }
}
#endif
