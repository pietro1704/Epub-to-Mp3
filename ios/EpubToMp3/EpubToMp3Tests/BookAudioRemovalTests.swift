import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

private actor BookRemovalGate {
    let entered: XCTestExpectation
    private var pending: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { pending = $0; entered.fulfill() }
    }
    func release() { pending?.resume(); pending = nil }
}

final class BookAudioRemovalTests: XCTestCase {
    enum Failure: Error { case denied }

    @MainActor
    func testSuccessUsesLiteralBookIdentityAndAllowsANewConfirmedAttempt() async throws {
        let removal = BookAudioRemoval()
        var received: [String] = []
        for _ in 0..<2 {
            let success = try await removal.remove(bookID: "book/á+1") { received.append($0) }
            XCTAssertTrue(success)
        }
        XCTAssertEqual(received, ["book/á+1", "book/á+1"])
    }

    @MainActor
    func testFailureIsNotReportedAsSuccessfulRemovalAndRetryRemainsAvailable() async throws {
        let removal = BookAudioRemoval()
        do {
            _ = try await removal.remove(bookID: "book") { _ in throw Failure.denied }
            XCTFail("A failed deletion must not clear the library's retained-download flag")
        } catch { XCTAssertTrue(error is Failure) }
        let retry = try await removal.remove(bookID: "book") { _ in }
        XCTAssertTrue(retry)
    }

    @MainActor
    func testDuplicateAttemptIsSuppressedWhileAnotherBookKeepsItsOwnIdentity() async throws {
        let removal = BookAudioRemoval()
        let entered = expectation(description: "First removal entered")
        let gate = BookRemovalGate(entered)
        var received: [String] = []
        let first = Task { try await removal.remove(bookID: "first") { received.append($0); await gate.wait() } }
        await fulfillment(of: [entered], timeout: 2)
        let duplicate = try await removal.remove(bookID: "first") { received.append($0) }
        let other = try await removal.remove(bookID: "other") { received.append($0) }
        await gate.release()
        let completed = try await first.value
        XCTAssertFalse(duplicate)
        XCTAssertTrue(other)
        XCTAssertTrue(completed)
        XCTAssertEqual(received, ["first", "other"])
    }

    @MainActor
    func testCancellationPropagatesAndDoesNotLockOutRetry() async throws {
        let removal = BookAudioRemoval()
        do {
            _ = try await removal.remove(bookID: "book") { _ in throw CancellationError() }
            XCTFail("Cancellation must not report successful deletion")
        } catch { XCTAssertTrue(error is CancellationError) }
        let retry = try await removal.remove(bookID: "book") { _ in }
        XCTAssertTrue(retry)
    }

    @MainActor
    func testAlreadyCancelledAttemptDoesNotInvokeDeletion() async {
        let removal = BookAudioRemoval()
        var invoked = false
        let task = Task { try await removal.remove(bookID: "book") { _ in invoked = true } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must stop before deletion") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(invoked)
    }
}
