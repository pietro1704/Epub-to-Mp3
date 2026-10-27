import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class RustConversionWorkQueuesTests: XCTestCase {
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func finish() { lock.lock(); value = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testManualConversionStartsWhileListeningWaitsForPlayback() async {
        let queues = RustConversionWorkQueues()
        let playbackWindow = DispatchSemaphore(value: 0)
        defer { playbackWindow.signal() }
        let listeningStarted = expectation(description: "Listening invocation entered playback wait")
        let listeningFinished = expectation(description: "Listening invocation released")
        let manualStarted = expectation(description: "Manual invocation starts without moving playback")
        queues.enqueue(for: .listening) {
            XCTAssertFalse(Thread.isMainThread)
            listeningStarted.fulfill()
            _ = playbackWindow.wait(timeout: .now() + 2)
            listeningFinished.fulfill()
        }
        await fulfillment(of: [listeningStarted], timeout: 1)
        queues.enqueue(for: .manual) {
            XCTAssertFalse(Thread.isMainThread)
            manualStarted.fulfill()
        }
        await fulfillment(of: [manualStarted], timeout: 0.2)
        playbackWindow.signal()
        await fulfillment(of: [listeningFinished], timeout: 1)
    }

    func testEachPurposeKeepsItsInvocationsSerial() async {
        for purpose in [RustConversionWorkQueues.Purpose.manual, .listening] {
            let queues = RustConversionWorkQueues()
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let finished = CompletionFlag()
            let firstStarted = expectation(description: "First invocation started")
            let secondFinished = expectation(description: "Second invocation finished")
            let overlap = expectation(description: "Invocations must not overlap within one purpose")
            overlap.isInverted = true
            queues.enqueue(for: purpose) {
                firstStarted.fulfill()
                _ = release.wait(timeout: .now() + 2)
                finished.finish()
            }
            await fulfillment(of: [firstStarted], timeout: 1)
            queues.enqueue(for: purpose) {
                if !finished.isFinished { overlap.fulfill() }
                secondFinished.fulfill()
            }
            await fulfillment(of: [overlap], timeout: 0.03)
            release.signal()
            await fulfillment(of: [secondFinished], timeout: 1)
        }
    }
}
