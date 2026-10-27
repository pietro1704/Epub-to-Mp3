import Combine
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

@MainActor
final class ManualConversionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class ManualConversionSessionTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/fixture-only/manual.epub")

    private func result(_ jobID: String) -> RustConversionCoordinator.Result {
        .init(jobID: jobID,
              manifestJSON: Data("{\"manifest\":{\"jobId\":\"\(jobID)\",\"title\":\"Manual fixture\",\"author\":\"Author\",\"chapters\":[]}}".utf8),
              outputDirectory: URL(fileURLWithPath: "/fixture-only/output"))
    }

    private func progress(_ jobID: String, percent: Double = 25) -> RustConversionCoordinator.ConversionProgressEvent {
        .init(jobId: jobID, state: "running", chapterIndex: 1, chaptersTotal: 4,
              chaptersCompleted: 1, percent: percent, engine: "piper", message: "Fixture progress")
    }

    func testProgressIsObservableBeforeConversionFinishesAndRepeatedSubmissionIsIgnored() async {
        let gate = ManualConversionGate()
        defer { gate.release() }
        let entered = expectation(description: "Executor published progress")
        var phases: [ManualConversionSession.Phase] = []
        var calls = 0
        let session = ManualConversionSession(executor: { _, jobID, start, end, _, update, _ in
            calls += 1
            XCTAssertEqual(start, 8)
            XCTAssertEqual(end, 9)
            update?(self.progress(jobID))
            entered.fulfill()
            await gate.wait()
            return self.result(jobID)
        })
        let observation = session.$phase.sink { phases.append($0) }
        defer { observation.cancel() }
        let pending = Task { await session.run(file: file, start: 8, end: 9, options: nil) }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(phases, [.idle, .preparing, .converting])
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.result)
        XCTAssertEqual(ManualConversionPresentation.title(for: session), L10n.string("convert.progressPercent", 25))
        XCTAssertEqual(ManualConversionPresentation.detail(for: session), L10n.string("convert.chapterProgress", 1, 4))
        session.reportValidationFailure("An unrelated edit must not retire this conversion")
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.phase, .converting)
        await session.run(file: file, start: -1, end: -1, options: nil)
        XCTAssertEqual(calls, 1)
        gate.release()
        await pending.value
        XCTAssertEqual(session.phase, .completed)
        XCTAssertFalse(session.isRunning)
        XCTAssertNotNil(session.result)
    }

    func testProviderFailureClearsBusyStateAndRetryCanSucceed() async {
        var calls = 0
        let session = ManualConversionSession(executor: { _, jobID, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provider failed"])
            }
            return self.result(jobID)
        })
        await session.run(file: file, start: -1, end: -1, options: nil)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.errorMessage, "Provider failed")
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.result)
        await session.run(file: file, start: -1, end: -1, options: nil)
        XCTAssertEqual(session.phase, .completed)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(calls, 2)
    }

    func testCancelWaitsForWriterAndRejectsLateProgressAndSuccess() async {
        let gate = ManualConversionGate()
        defer { gate.release() }
        let entered = expectation(description: "Writer is running")
        var emit: (@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?
        var jobID = ""
        let session = ManualConversionSession(executor: { _, id, _, _, _, update, _ in
            jobID = id
            emit = update
            update?(self.progress(id))
            entered.fulfill()
            await gate.wait()
            return self.result(id)
        })
        let pending = Task { await session.run(file: file, start: -1, end: -1, options: nil) }
        await fulfillment(of: [entered], timeout: 1)
        session.cancel()
        session.cancel()
        XCTAssertEqual(session.phase, .cancelling)
        XCTAssertTrue(session.isRunning, "The writer still owns its output and file access")
        emit?(progress(jobID, percent: 100))
        XCTAssertEqual(session.progress?.percent, 25)
        gate.release()
        await pending.value
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertFalse(session.isRunning)
        XCTAssertNil(session.result)
        XCTAssertNil(session.errorMessage, "Explicit cancellation is not a provider failure")
        emit?(progress(jobID, percent: 100))
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertEqual(ManualConversionPresentation.detail(for: session), L10n.string("convert.cancelled"))
    }

    func testCallerCancellationReachesTheOwnedExecutor() async {
        let gate = ManualConversionGate()
        defer { gate.release() }
        let entered = expectation(description: "Executor entered")
        let cancelled = expectation(description: "Executor cancellation handler ran")
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in
            try await withTaskCancellationHandler(operation: {
                entered.fulfill()
                await gate.wait()
                return self.result(id)
            }, onCancel: { cancelled.fulfill() })
        })
        let pending = Task { await session.run(file: file, start: -1, end: -1, options: nil) }
        await fulfillment(of: [entered], timeout: 1)
        pending.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        gate.release()
        await pending.value
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertNil(session.result)
    }

    func testCancelledCallerNeverStartsAProducer() async {
        let admission = ManualConversionGate()
        var calls = 0
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in
            calls += 1
            return self.result(id)
        })
        let pending = Task {
            await admission.wait()
            await session.run(file: file, start: -1, end: -1, options: nil)
        }
        pending.cancel()
        admission.release()
        await pending.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertFalse(session.isRunning)
    }

    func testStaleAndForeignProgressCannotReplaceTheCurrentRequest() async {
        let gate = ManualConversionGate()
        defer { gate.release() }
        let secondEntered = expectation(description: "Replacement request running")
        var callbacks: [@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void] = []
        var jobIDs: [String] = []
        let session = ManualConversionSession(executor: { _, id, _, _, _, update, _ in
            jobIDs.append(id)
            if let update { callbacks.append(update) }
            if jobIDs.count == 2 { secondEntered.fulfill(); await gate.wait() }
            return self.result(id)
        })
        await session.run(file: file, start: -1, end: -1, options: nil)
        let replacement = Task { await session.run(file: file, start: 8, end: 9, options: nil) }
        await fulfillment(of: [secondEntered], timeout: 1)
        XCTAssertEqual(jobIDs.count, 2)
        XCTAssertNotEqual(jobIDs[0], jobIDs[1])
        callbacks[0](progress(jobIDs[1], percent: 90))
        callbacks[1](progress("another-job", percent: 80))
        XCTAssertNil(session.progress)
        XCTAssertEqual(session.phase, .preparing)
        callbacks[1](progress(jobIDs[1], percent: 100))
        XCTAssertEqual(ManualConversionPresentation.title(for: session), L10n.string("convert.progressPercent", 99),
                       "An event at 100 percent is not committed completion")
        gate.release()
        await replacement.value
        callbacks[1](progress(jobIDs[1], percent: 10))
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(session.result?.jobID, jobIDs[1])
    }

    func testValidationFailureClearsThePreviousResult() async {
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in self.result(id) })
        await session.run(file: file, start: -1, end: -1, options: nil)
        XCTAssertNotNil(session.result)
        session.reportValidationFailure("Choose a supported file")
        XCTAssertNil(session.result)
        XCTAssertNil(session.progress)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.errorMessage, "Choose a supported file")
    }

    func testCancellationAfterCommittedCompletionDoesNotEraseTheResult() async {
        let session = ManualConversionSession(executor: { _, id, _, _, _, _, _ in self.result(id) })
        await session.run(file: file, start: -1, end: -1, options: nil)
        let committedID = session.result?.jobID
        session.cancel()
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(session.result?.jobID, committedID)
        XCTAssertNotNil(committedID)
    }
}
