#if canImport(AVFoundation)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// First-slice unit tests for `SpeechFallbackPlayer`.
///
/// The service is an iOS/macOS accessibility-speech fallback for when
/// the generated MP3 stream isn't ready or playable: it speaks the
/// chapter text aloud via `AVSpeechSynthesizer`. These tests cover the
/// state machine, audio-session handling, and language fallback; they
/// do NOT exercise real speech synthesis or activate the system audio
/// session — both are stubbed via dependency-injected fakes.
final class SpeechFallbackPlayerTests: XCTestCase {

    // MARK: Fakes

    /// Records every interaction with the synthesizer so the test can
    /// assert what was enqueued, whether pause/continue/stop were
    /// called, and trigger the delegate callbacks manually.
    final class FakeSynthesizer: SpeechSynthesizing {
        weak var delegate: AVSpeechSynthesizerDelegate?
        private(set) var isSpeaking: Bool = false
        private(set) var isPaused: Bool = false
        private(set) var spoken: [AVSpeechUtterance] = []
        private(set) var pauseCalls = 0
        private(set) var continueCalls = 0
        private(set) var stopCalls = 0

        func speak(_ utterance: AVSpeechUtterance) {
            spoken.append(utterance)
            isSpeaking = true
            isPaused = false
        }

        @discardableResult
        func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            pauseCalls += 1
            isPaused = true
            return true
        }

        @discardableResult
        func continueSpeaking() -> Bool {
            continueCalls += 1
            isPaused = false
            return true
        }

        @discardableResult
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            stopCalls += 1
            isSpeaking = false
            isPaused = false
            spoken.removeAll()
            return true
        }

        /// Fires the AVSpeechSynthesizerDelegate `didFinish` callback so
        /// tests can assert that the player resets to `.idle` when the
        /// synthesizer reaches end-of-utterance.
        func simulateFinish(_ utterance: AVSpeechUtterance) {
            isSpeaking = false
            let dummy = AVSpeechSynthesizer()
            delegate?.speechSynthesizer?(dummy, didFinish: utterance)
        }
    }

    /// Records how many times the configurator was asked to prep the
    /// audio session for speech, and what category/mode were used.
    final class FakeSpeechAudioSession: SpeechAudioSessionConfiguring {
        private(set) var configureCalls = 0
        private(set) var lastCategory: String?
        private(set) var lastMode: String?

        func configureForSpeech() throws {
            configureCalls += 1
            lastCategory = "playback"
            lastMode = "spokenAudio"
        }
    }

    // MARK: Helpers

    @MainActor
    private func makePlayer() -> (SpeechFallbackPlayer, FakeSynthesizer, FakeSpeechAudioSession) {
        let synth = FakeSynthesizer()
        let session = FakeSpeechAudioSession()
        let player = SpeechFallbackPlayer(synthesizer: synth, sessionConfigurator: session)
        return (player, synth, session)
    }

    // MARK: Tests

    @MainActor
    func test_initialState_isIdle() {
        let (player, _, _) = makePlayer()
        XCTAssertEqual(player.state, .idle)
    }

    @MainActor
    func test_init_doesNotActivateAudioSession() {
        let (_, _, session) = makePlayer()
        XCTAssertEqual(
            session.configureCalls, 0,
            "init must never touch the audio session — Spotify and other apps would be interrupted"
        )
    }

    @MainActor
    func test_speak_enqueuesChapterTextAndSwitchesToSpeaking() {
        let (player, synth, _) = makePlayer()
        player.speak(text: "Once upon a time.", languageCode: "en-US")
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(synth.spoken.first?.speechString, "Once upon a time.")
        XCTAssertEqual(player.state, .speaking)
    }

    @MainActor
    func test_speak_configuresPlaybackSpokenAudioSession() {
        let (player, _, session) = makePlayer()
        player.speak(text: "Hello.", languageCode: "en-US")
        XCTAssertEqual(session.configureCalls, 1)
        XCTAssertEqual(session.lastCategory, "playback")
        XCTAssertEqual(session.lastMode, "spokenAudio")
    }

    @MainActor
    func test_speak_emptyText_isNoOp() {
        let (player, synth, session) = makePlayer()
        player.speak(text: "", languageCode: "en-US")
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertEqual(session.configureCalls, 0)
        XCTAssertEqual(player.state, .idle)
    }

    @MainActor
    func test_speak_unknownLanguage_fallsBackSafely() {
        let (player, synth, _) = makePlayer()
        // Bogus BCP-47 tag — no matching voice. The player should still
        // speak (using the default system voice) rather than crash or
        // silently drop the utterance.
        player.speak(text: "Hello.", languageCode: "zz-ZZ")
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(player.state, .speaking)
    }

    @MainActor
    func test_pauseThenResume_doesNotReenqueueUtterance() {
        let (player, synth, _) = makePlayer()
        player.speak(text: "A long passage.", languageCode: "en-US")
        XCTAssertEqual(synth.spoken.count, 1)

        player.pause()
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(synth.pauseCalls, 1)

        player.resume()
        XCTAssertEqual(player.state, .speaking)
        XCTAssertEqual(synth.continueCalls, 1)
        XCTAssertEqual(
            synth.spoken.count, 1,
            "resume must continue the existing utterance, not re-enqueue a new one"
        )
    }

    @MainActor
    func test_stop_clearsQueueAndReturnsIdle() {
        let (player, synth, _) = makePlayer()
        player.speak(text: "Hello.", languageCode: "en-US")
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(synth.stopCalls, 1)
        XCTAssertTrue(synth.spoken.isEmpty)
    }

    @MainActor
    func test_delegateFinish_returnsToIdle() {
        let (player, synth, _) = makePlayer()
        player.speak(text: "Hello.", languageCode: "en-US")
        let utterance = synth.spoken[0]
        synth.simulateFinish(utterance)
        let exp = expectation(description: "state returns to idle")
        Task { @MainActor in
            for _ in 0..<50 {
                if player.state == .idle {
                    exp.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("Speech fallback did not return to idle after delegate finish")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
}
#endif
