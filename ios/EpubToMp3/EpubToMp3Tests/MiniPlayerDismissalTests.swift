import XCTest
@testable import EpubToMp3

final class MiniPlayerDismissalTests: XCTestCase {
    func testDismissalSurvivesNavigationAndRelaunchUntilNewPlaybackForThatBook() throws {
        let suite = "MiniDismissal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MiniPlayerDismissal(defaults: defaults)
        state.dismiss(bookID: "first")
        state.dismiss(bookID: "second")
        XCTAssertTrue(MiniPlayerDismissal(defaults: defaults).isDismissed(bookID: "first"))
        XCTAssertFalse(state.isDismissed(bookID: "unrelated"))
        state.allowPlayback(bookID: "second")
        XCTAssertTrue(state.isDismissed(bookID: "first"))
        XCTAssertFalse(state.isDismissed(bookID: "second"))
        state.allowPlayback(bookID: "first")
        XCTAssertFalse(state.isDismissed(bookID: "first"))
    }

    func testDismissalCannotReviveTheOldAudioBookAfterReturningFromAnotherReader() throws {
        let suite = "MiniContexts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MiniPlayerDismissal(defaults: defaults)
        state.dismiss(readingBookID: "visible-reader", playingBookID: "playing-book")
        XCTAssertTrue(state.isDismissed(bookID: "visible-reader"))
        XCTAssertTrue(state.isDismissed(bookID: "playing-book"))
        XCTAssertFalse(state.isDismissed(bookID: "another-book"))
        state.allowPlayback(bookID: "playing-book")
        XCTAssertFalse(state.isDismissed(bookID: "playing-book"))
        XCTAssertTrue(state.isDismissed(bookID: "visible-reader"))
    }

    func testShortCancelledAndUpwardDragsNeverDismiss() {
        XCTAssertFalse(MiniPlayerDismissal.shouldDismiss(distance: 15, velocity: 50, height: 60, cancelled: false))
        XCTAssertFalse(MiniPlayerDismissal.shouldDismiss(distance: -80, velocity: 900, height: 60, cancelled: false))
        XCTAssertFalse(MiniPlayerDismissal.shouldDismiss(distance: 80, velocity: 900, height: 60, cancelled: true))
        XCTAssertTrue(MiniPlayerDismissal.shouldDismiss(distance: 40, velocity: 50, height: 60, cancelled: false))
        XCTAssertTrue(MiniPlayerDismissal.shouldDismiss(distance: 20, velocity: 900, height: 60, cancelled: false))
    }
}
