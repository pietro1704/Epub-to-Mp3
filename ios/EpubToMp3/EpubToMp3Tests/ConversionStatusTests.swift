import XCTest
@testable import EpubToMp3

/// Unit tests for `ConversionStatus`:
/// ring-buffer cap, event recording, chapter tracking, error tracking,
/// and session lifecycle (beginSession / endSession).
///
/// All tests are `@MainActor` because `ConversionStatus` is isolated to
/// the main actor.
@MainActor
final class ConversionStatusTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let status = ConversionStatus()
        XCTAssertTrue(status.events.isEmpty)
        XCTAssertNil(status.currentChapterName)
        XCTAssertNil(status.currentChapterIndex)
        XCTAssertNil(status.lastError)
        XCTAssertNil(status.startedAt)
        XCTAssertNil(status.elapsedSeconds)
    }

    // MARK: - beginSession / endSession

    func testBeginSessionSetsStartedAt() {
        let status = ConversionStatus()
        let before = Date()
        status.beginSession()
        let after = Date()
        XCTAssertNotNil(status.startedAt)
        XCTAssertGreaterThanOrEqual(status.startedAt!, before)
        XCTAssertLessThanOrEqual(status.startedAt!, after)
    }

    func testBeginSessionClearsPriorState() {
        let status = ConversionStatus()
        status.beginSession()
        status.setCurrentChapter(index: 3, name: "Chapter 4")
        status.record(.error, "Some error")
        status.record(.info, "An event")

        // Second begin should wipe everything.
        status.beginSession()

        XCTAssertTrue(status.events.isEmpty, "beginSession must clear events")
        XCTAssertNil(status.currentChapterName, "beginSession must clear chapter name")
        XCTAssertNil(status.currentChapterIndex, "beginSession must clear chapter index")
        XCTAssertNil(status.lastError, "beginSession must clear lastError")
        XCTAssertNotNil(status.startedAt, "beginSession must set a new startedAt")
    }

    func testEndSessionClearsStartedAt() {
        let status = ConversionStatus()
        status.beginSession()
        XCTAssertNotNil(status.startedAt)
        status.endSession()
        XCTAssertNil(status.startedAt)
        XCTAssertNil(status.elapsedSeconds)
    }

    // MARK: - record events

    func testRecordAppendsSingleEvent() {
        let status = ConversionStatus()
        status.record(.info, "Hello")
        XCTAssertEqual(status.events.count, 1)
        XCTAssertEqual(status.events[0].message, "Hello")
        XCTAssertEqual(status.events[0].kind, .info)
    }

    func testRecordMultipleEventsInOrder() {
        let status = ConversionStatus()
        status.record(.chunkStart, "start")
        status.record(.chunkComplete, "complete")
        status.record(.chapterComplete, "chapter done")
        XCTAssertEqual(status.events.count, 3)
        XCTAssertEqual(status.events[0].kind, .chunkStart)
        XCTAssertEqual(status.events[1].kind, .chunkComplete)
        XCTAssertEqual(status.events[2].kind, .chapterComplete)
    }

    func testErrorEventSetsLastError() {
        let status = ConversionStatus()
        XCTAssertNil(status.lastError)
        status.record(.error, "TTS timeout")
        XCTAssertEqual(status.lastError, "TTS timeout")
    }

    func testNonErrorEventDoesNotSetLastError() {
        let status = ConversionStatus()
        status.record(.info, "Just info")
        XCTAssertNil(status.lastError)
    }

    func testMultipleErrorsLastErrorIsNewest() {
        let status = ConversionStatus()
        status.record(.error, "First error")
        status.record(.error, "Second error")
        XCTAssertEqual(status.lastError, "Second error")
    }

    // MARK: - Ring buffer cap (max 50 events)

    func testRingBufferCapAt50() {
        let status = ConversionStatus()
        for i in 0..<60 {
            status.record(.info, "event \(i)")
        }
        XCTAssertEqual(status.events.count, 50,
            "Ring buffer must not exceed 50 events")
    }

    func testRingBufferRetainsNewestEvents() {
        let status = ConversionStatus()
        for i in 0..<60 {
            status.record(.info, "event \(i)")
        }
        // After 60 inserts with cap=50, the first surviving entry
        // must be "event 10" (indices 10–59).
        XCTAssertEqual(status.events.first?.message, "event 10",
            "Ring buffer must drop the oldest events first")
        XCTAssertEqual(status.events.last?.message, "event 59")
    }

    func testRingBufferExactlyAtCapNoDrop() {
        let status = ConversionStatus()
        for i in 0..<50 {
            status.record(.info, "event \(i)")
        }
        XCTAssertEqual(status.events.count, 50)
        XCTAssertEqual(status.events.first?.message, "event 0")
    }

    // MARK: - Chapter tracking

    func testSetCurrentChapter() {
        let status = ConversionStatus()
        status.setCurrentChapter(index: 5, name: "The Battle of Five Armies")
        XCTAssertEqual(status.currentChapterIndex, 5)
        XCTAssertEqual(status.currentChapterName, "The Battle of Five Armies")
    }

    func testSetCurrentChapterOverwritesPrevious() {
        let status = ConversionStatus()
        status.setCurrentChapter(index: 0, name: "Prologue")
        status.setCurrentChapter(index: 1, name: "Chapter 1")
        XCTAssertEqual(status.currentChapterIndex, 1)
        XCTAssertEqual(status.currentChapterName, "Chapter 1")
    }

    // MARK: - clearError

    func testClearErrorRemovesLastError() {
        let status = ConversionStatus()
        status.record(.error, "Something failed")
        XCTAssertNotNil(status.lastError)
        status.clearError()
        XCTAssertNil(status.lastError)
    }

    // MARK: - elapsedSeconds

    func testElapsedSecondsIsNilWhenNotStarted() {
        let status = ConversionStatus()
        XCTAssertNil(status.elapsedSeconds)
    }

    func testElapsedSecondsIsNonNegativeWhenStarted() {
        let status = ConversionStatus()
        status.beginSession()
        guard let elapsed = status.elapsedSeconds else {
            XCTFail("elapsedSeconds must not be nil after beginSession")
            return
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0,
            "elapsedSeconds must be non-negative immediately after beginSession")
    }

    // MARK: - EventKind.systemImage (coverage)

    func testAllKindsHaveNonEmptySystemImage() {
        let kinds: [ConversionStatus.EventKind] = [
            .chunkStart, .chunkComplete, .chapterComplete, .error, .info
        ]
        for kind in kinds {
            XCTAssertFalse(kind.systemImage.isEmpty,
                "\(kind) must have a non-empty systemImage name")
        }
    }

    // MARK: - AudioPlayer integration

    func testAudioPlayerExposesConversionStatus() throws {
        // Ensure AudioPlayer owns a ConversionStatus instance.
        let player = AudioPlayer()
        // Just verifying the property exists and is the right type.
        let status: ConversionStatus = player.conversionStatus
        XCTAssertTrue(status.events.isEmpty, "Fresh player status must be idle")
    }

    func testClearConversionStateCallsEndSession() {
        let player = AudioPlayer()
        player.conversionStatus.beginSession()
        XCTAssertNotNil(player.conversionStatus.startedAt)
        player.clearConversionState()
        XCTAssertNil(player.conversionStatus.startedAt,
            "clearConversionState must call endSession on conversionStatus")
    }

    func testEnqueueSegmentRecordsChunkCompleteEvent() {
        let player = AudioPlayer()
        // Start a session so events are meaningful.
        player.conversionStatus.beginSession()
        let mp3 = fakeMP3()
        player.enqueueSegment(data: mp3, chapterIndex: 0, segmentIndex: 2)
        XCTAssertTrue(
            player.conversionStatus.events.contains(where: { $0.kind == .chunkComplete }),
            "enqueueSegment must record a .chunkComplete event"
        )
    }

    func testMarkFirstChapterReadyRecordsChapterCompleteEvent() {
        let player = AudioPlayer()
        player.conversionStatus.beginSession()
        player.markFirstChapterReady()
        XCTAssertTrue(
            player.conversionStatus.events.contains(where: { $0.kind == .chapterComplete }),
            "markFirstChapterReady must record a .chapterComplete event"
        )
    }

    func testRecordConversionErrorSetsLastError() {
        let player = AudioPlayer()
        player.recordConversionError("Chapter 3 timeout")
        XCTAssertEqual(player.conversionStatus.lastError, "Chapter 3 timeout")
    }

    // MARK: - Helpers

    private func fakeMP3(size: Int = 512) -> Data {
        var d = Data([0xFF, 0xFB, 0x90, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0x00, count: max(0, size - 4)))
        return d
    }
}
