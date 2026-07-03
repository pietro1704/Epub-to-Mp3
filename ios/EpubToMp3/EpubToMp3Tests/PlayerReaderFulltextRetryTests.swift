import XCTest
@testable import EpubToMp3

/// Unit tests for the SSE-driven fulltext auto-retry decision (Bug A).
///
/// When an EPUB parse outlasts the retry ladder inside a single
/// `FulltextStore.refresh()` (~23 s), the reader text used to stay stuck in an
/// error state until the user tapped Retry — even though the live audio stream
/// kept delivering chapter-progress snapshots. `shouldAutoRetryFulltext` lets
/// each incoming snapshot re-arm the fulltext load once the parse finishes,
/// gated so it never spams the backend or fights an in-flight load.
final class PlayerReaderFulltextRetryTests: XCTestCase {

    private let interval: TimeInterval = 8
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func decide(
        hasFulltext: Bool = false,
        jobIsTerminal: Bool = false,
        hasBackend: Bool = true,
        loadInFlight: Bool = false,
        secondsSinceLastRetry: TimeInterval = 100
    ) -> Bool {
        PlayerReaderView.shouldAutoRetryFulltext(
            hasFulltext: hasFulltext,
            jobIsTerminal: jobIsTerminal,
            hasBackend: hasBackend,
            loadInFlight: loadInFlight,
            now: now,
            lastRetryAt: now.addingTimeInterval(-secondsSinceLastRetry),
            minInterval: interval
        )
    }

    func testRetriesWhenTextPendingAndJobRunning() {
        XCTAssertTrue(decide(), "A running job with no text and an idle loader past the debounce must re-fetch.")
    }

    func testDoesNotRetryWhenTextAlreadyLoaded() {
        XCTAssertFalse(decide(hasFulltext: true))
    }

    func testDoesNotRetryWhenJobTerminal() {
        // Terminal (failed/finished/cancelled) → polling can't help; the text
        // is genuinely gone or the parse is truly done.
        XCTAssertFalse(decide(jobIsTerminal: true))
    }

    func testDoesNotRetryWithoutBackend() {
        XCTAssertFalse(decide(hasBackend: false))
    }

    func testDoesNotRetryWhileLoadInFlight() {
        XCTAssertFalse(decide(loadInFlight: true),
                       "A load already running must not be duplicated.")
    }

    func testDoesNotRetryInsideDebounceWindow() {
        XCTAssertFalse(decide(secondsSinceLastRetry: 3),
                       "Bursts of progress snapshots must not hammer the fulltext endpoint.")
    }

    func testRetriesExactlyAtDebounceBoundary() {
        XCTAssertTrue(decide(secondsSinceLastRetry: interval),
                      "The debounce is inclusive at the boundary.")
    }
}
