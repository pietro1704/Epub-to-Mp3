import XCTest
@testable import EpubToMp3

final class ReaderPresentationStateTests: XCTestCase {
    func testActiveVisibleReaderShowsNavigationAndMiniPlayer() {
        let state = ReaderPresentationState(isReaderActive: true)

        XCTAssertTrue(state.showsReaderNavigation)
        XCTAssertFalse(state.hidesBottomChrome)
        XCTAssertTrue(state.showsMiniPlayer(bookHasPlayback: true))
    }

    func testLoadingOrImmersiveReaderHidesBottomChrome() {
        var state = ReaderPresentationState(isReaderActive: true, isLoading: true)
        XCTAssertTrue(state.hidesBottomChrome)
        XCTAssertFalse(state.showsMiniPlayer(bookHasPlayback: true))

        state.isLoading = false
        state.isChromeHidden = true
        XCTAssertTrue(state.hidesBottomChrome)
        XCTAssertFalse(state.showsReaderNavigation)
        XCTAssertFalse(state.showsMiniPlayer(bookHasPlayback: true))
    }

    func testInactiveReaderResetsPresentationFacts() {
        var state = ReaderPresentationState(
            isReaderActive: true,
            isLoading: true,
            isChromeHidden: true
        )

        state.resetForInactiveReader()

        XCTAssertEqual(state, ReaderPresentationState())
        XCTAssertFalse(state.showsMiniPlayer(bookHasPlayback: true))
    }
}
