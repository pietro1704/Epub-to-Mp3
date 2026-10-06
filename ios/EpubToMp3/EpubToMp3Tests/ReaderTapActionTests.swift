import XCTest
@testable import EpubToMp3

#if os(iOS)
final class ReaderTapActionTests: XCTestCase {
    private let readerBounds = CGRect(x: 0, y: 0, width: 390, height: 760)

    func testReaderNavigationIsBlockedUntilLoadingOverlayIsGone() {
        XCTAssertFalse(
            BookOpenScreenController.allowsReaderNavigation(
                isDeferringReaderGestures: true,
                isLoadingOverlayHidden: false
            )
        )
        XCTAssertFalse(
            BookOpenScreenController.allowsReaderNavigation(
                isDeferringReaderGestures: false,
                isLoadingOverlayHidden: false
            )
        )
        XCTAssertTrue(
            BookOpenScreenController.allowsReaderNavigation(
                isDeferringReaderGestures: false,
                isLoadingOverlayHidden: true
            )
        )
    }

    func testCenterTapAlwaysTogglesReaderChrome() {
        for y in [20, 380, 740] {
            XCTAssertEqual(
                ReaderTapAction.resolve(
                    point: CGPoint(x: 195, y: CGFloat(y)),
                    in: readerBounds,
                    isPaginated: true
                ),
                .toggleChrome,
                "The middle reading column must toggle chrome at every vertical position."
            )
        }
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
