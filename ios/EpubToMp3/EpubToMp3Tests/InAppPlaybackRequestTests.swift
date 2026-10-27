import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class InAppPlaybackRequestTests: XCTestCase {
    private func assertRoute(
        _ state: InAppPlaybackRequest.State,
        expectedStarts: Int,
        expectedControls: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var starts = 0
        var controls = 0
        InAppPlaybackRequest.perform(state: state, controlPlayback: { controls += 1 },
                                     startListening: { starts += 1 })
        XCTAssertEqual(starts, expectedStarts, file: file, line: line)
        XCTAssertEqual(controls, expectedControls, file: file, line: line)
    }

    func testFirstPlayRequestsListeningInsteadOfArmingAnUnconsumedResume() {
        assertRoute(.init(), expectedStarts: 1, expectedControls: 0)
    }

    func testPreparedAudioControlsTheExistingQueue() {
        assertRoute(.init(hasAudioQueue: true), expectedStarts: 0, expectedControls: 1)
    }

    func testConversionInProgressNeverStartsAnotherProducer() {
        assertRoute(.init(isConverting: true), expectedStarts: 0, expectedControls: 1)
    }

    func testRestoredPlayableChaptersResumeWithoutAnotherConversion() {
        assertRoute(.init(hasPlayableChapters: true), expectedStarts: 0, expectedControls: 1)
    }

    func testPlayingWithoutAQueueStillReceivesPause() {
        assertRoute(.init(isPlaying: true), expectedStarts: 0, expectedControls: 1)
    }

    func testPausedSpeechFallbackResumesItsExistingSynthesizer() {
        assertRoute(.init(usesSpeechFallback: true), expectedStarts: 0, expectedControls: 1)
    }

    func testRepeatedPlayDuringPreparationDoesNotStartListeningTwice() {
        var state = InAppPlaybackRequest.State()
        var starts = 0
        var controls = 0
        for _ in 0..<2 {
            InAppPlaybackRequest.perform(state: state, controlPlayback: { controls += 1 }, startListening: {
                starts += 1
                state.isConverting = true
            })
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(controls, 1)
    }

    func testSequentialRequestsUseOnlyTheirOwnCommandClosures() {
        var first = 0
        var replacement = 0
        InAppPlaybackRequest.perform(state: .init(isConverting: true), controlPlayback: { first += 1 },
                                     startListening: { XCTFail("Conversion already exists") })
        InAppPlaybackRequest.perform(state: .init(), controlPlayback: { XCTFail("No replacement queue") },
                                     startListening: { replacement += 1 })
        XCTAssertEqual(first, 1)
        XCTAssertEqual(replacement, 1)
    }

    func testRejectedListeningAdmissionCanBeRetriedWithoutAStuckResumeIntent() {
        var admissions = 0
        for _ in 0..<2 {
            InAppPlaybackRequest.perform(state: .init(), controlPlayback: { XCTFail("No active session") },
                                         startListening: { admissions += 1 })
        }
        XCTAssertEqual(admissions, 2)
    }
}
