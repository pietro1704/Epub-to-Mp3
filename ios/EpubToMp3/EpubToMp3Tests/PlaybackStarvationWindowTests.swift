import XCTest
@testable import EpubToMp3

@MainActor
final class PlaybackStarvationWindowTests: XCTestCase {
    @MainActor private final class Recorder {
        var begun = 0
        var ended: [Int] = []
        var expire: (@MainActor () -> Void)?
        func window() -> PlaybackStarvationWindow {
            PlaybackStarvationWindow(begin: { [self] _, expired in
                begun += 1; expire = expired; return begun
            }, end: { [self] in ended.append($0) })
        }
    }

    func testHoldsWindowWhenDrainedQueueAwaitsSynthesisAndEndsWhenRenderingResumes() {
        let recorder = Recorder()
        let window = recorder.window()
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        XCTAssertEqual(recorder.begun, 1, "One window per starvation")
        XCTAssertTrue(window.isHeld)
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: true)
        XCTAssertFalse(window.isHeld)
        XCTAssertEqual(recorder.ended, [1])
    }

    func testNoWindowForIntentionalPauseOrFinishedSynthesis() {
        let recorder = Recorder()
        let window = recorder.window()
        window.update(wantsAudio: false, awaitingSynthesis: true, isRendering: false)
        window.update(wantsAudio: true, awaitingSynthesis: false, isRendering: false)
        XCTAssertEqual(recorder.begun, 0)
    }

    func testPauseOrCompletionReleasesHeldWindow() {
        let recorder = Recorder()
        let window = recorder.window()
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        window.update(wantsAudio: false, awaitingSynthesis: true, isRendering: false)
        XCTAssertEqual(recorder.ended, [1])
    }

    func testExpiryEndsWindowAndDoesNotChurnUntilAudioRendersAgain() {
        let recorder = Recorder()
        let window = recorder.window()
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        recorder.expire?()
        XCTAssertEqual(recorder.ended, [1])
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        XCTAssertEqual(recorder.begun, 1)
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: true)
        window.update(wantsAudio: true, awaitingSynthesis: true, isRendering: false)
        XCTAssertEqual(recorder.begun, 2)
    }

    func testQueueTeardownReleasesWindow() {
        let session = PlaybackQueueSession()
        session.teardown()
        XCTAssertFalse(session.starvation.isHeld)
    }
}
