#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Slice-2 tests: wire `SpeechFallbackPlayer` into `AudioPlayer` so the
/// reader/player flow can fall back to accessibility speech when the
/// generated MP3 stream is not ready or not playable AND the chapter
/// text is available.
///
/// The MP3 path remains the primary transport — fallback only activates
/// when the caller explicitly invokes `playFallbackSpeech(...)` AND the
/// snapshot tells us no playable chapter URL exists at the requested
/// index (or the snapshot is missing entirely). Once MP3 audio becomes
/// available, calling `play(snapshot:)` must stop the speech fallback
/// in the same turn so the UI never shows both transports at once.
///
/// Tests reuse the `FakeSynthesizer` / `FakeSpeechAudioSession` fakes
/// declared in `SpeechFallbackPlayerTests`. The fallback player is
/// injected into the AudioPlayer's init so neither AV nor the system
/// audio session are touched during the run.
@MainActor
final class AudioPlayerSpeechFallbackTests: XCTestCase {

    // MARK: - Helpers

    private func makeAudioPlayer() -> (
        AudioPlayer,
        SpeechFallbackPlayerTests.FakeSynthesizer,
        SpeechFallbackPlayerTests.FakeSpeechAudioSession
    ) {
        let synth = SpeechFallbackPlayerTests.FakeSynthesizer()
        let session = SpeechFallbackPlayerTests.FakeSpeechAudioSession()
        let fallback = SpeechFallbackPlayer(
            synthesizer: synth,
            sessionConfigurator: session
        )
        let player = AudioPlayer(speechFallback: fallback)
        return (player, synth, session)
    }

    private func snapshot(
        chapters: [JobSnapshot.Chapter],
        state: String = "running"
    ) -> JobSnapshot {
        JobSnapshot(
            jobId: "slice2-job",
            state: state,
            bookTitle: "Slice 2",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: chapters.count,
            chaptersCompleted: chapters.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }

    private func playableChapter(index: Int) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: "completed",
            downloadUrl: "http://example.invalid/ch-\(index).mp3",
            chars: 1234,
            charsProcessed: 1234,
            progressRatio: 1.0,
            durationSeconds: 60,
            startedAt: 0,
            completedAt: 0
        )
    }

    private func pendingChapter(index: Int) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: "pending",
            downloadUrl: nil,
            chars: 1234,
            charsProcessed: 0,
            progressRatio: 0.0,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )
    }

    // MARK: - Initial state

    func test_init_doesNotEnterSpeechFallback() {
        let (player, synth, session) = makeAudioPlayer()
        XCTAssertFalse(player.isUsingSpeechFallback,
            "fallback must be off until the host opts in")
        XCTAssertEqual(synth.spoken.count, 0)
        XCTAssertEqual(session.configureCalls, 0,
            "init must never configure the system audio session")
    }

    // MARK: - shouldUseSpeechFallback decision

    func test_shouldUseSpeechFallback_trueWhenNoSnapshot() {
        let (player, _, _) = makeAudioPlayer()
        XCTAssertTrue(
            player.shouldUseSpeechFallback(for: nil, chapterIndex: 0),
            "no snapshot ⇒ no MP3 path ⇒ fallback should be offered"
        )
    }

    func test_shouldUseSpeechFallback_trueWhenPlayableChaptersEmpty() {
        let (player, _, _) = makeAudioPlayer()
        let snap = snapshot(chapters: [pendingChapter(index: 0)])
        XCTAssertTrue(snap.playableChapters.isEmpty,
            "precondition: chapter has no downloadUrl yet")
        XCTAssertTrue(
            player.shouldUseSpeechFallback(for: snap, chapterIndex: 0),
            "no playable chapter URLs ⇒ MP3 path not ready ⇒ fallback should be offered"
        )
    }

    func test_shouldUseSpeechFallback_falseWhenChapterIsPlayable() {
        let (player, _, _) = makeAudioPlayer()
        let snap = snapshot(chapters: [playableChapter(index: 0), playableChapter(index: 1)])
        XCTAssertFalse(
            player.shouldUseSpeechFallback(for: snap, chapterIndex: 0),
            "MP3 is ready for this chapter ⇒ fallback must NOT preempt the primary path"
        )
        XCTAssertFalse(
            player.shouldUseSpeechFallback(for: snap, chapterIndex: 1),
            "MP3 is ready for chapter 1 ⇒ fallback must NOT preempt"
        )
    }

    func test_shouldUseSpeechFallback_trueWhenChapterIndexOutOfRange() {
        let (player, _, _) = makeAudioPlayer()
        let snap = snapshot(chapters: [playableChapter(index: 0)])
        XCTAssertTrue(
            player.shouldUseSpeechFallback(for: snap, chapterIndex: 5),
            "no playable chapter at the requested index ⇒ fallback should be offered"
        )
    }

    func test_shouldUseSpeechFallback_trueWhenChapterAtIndexIsPending() {
        let (player, _, _) = makeAudioPlayer()
        // Chapter 0 is done but chapter 1 still has no MP3 — caller asks
        // about chapter 1 because that's where the user wants to start.
        let snap = snapshot(chapters: [playableChapter(index: 0), pendingChapter(index: 1)])
        XCTAssertTrue(
            player.shouldUseSpeechFallback(for: snap, chapterIndex: 1),
            "even though some chapters are playable, the REQUESTED chapter has no URL"
        )
    }

    // MARK: - playFallbackSpeech

    func test_playFallbackSpeech_speaksTextAndEntersFallbackMode() {
        let (player, synth, session) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Once upon a time.", languageCode: "en-US")
        XCTAssertTrue(player.isUsingSpeechFallback,
            "fallback flag must flip after a successful speak call")
        XCTAssertTrue(player.isPlaying,
            "user-visible transport state must reflect that audio is playing")
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(synth.spoken.first?.speechString, "Once upon a time.")
        XCTAssertEqual(session.configureCalls, 1,
            "only the speech audio-session category should be configured — no MP3 session")
    }

    func test_playFallbackSpeech_emptyText_isNoOp() {
        let (player, synth, session) = makeAudioPlayer()
        player.playFallbackSpeech(text: "", languageCode: "en-US")
        XCTAssertFalse(player.isUsingSpeechFallback)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(synth.spoken.count, 0)
        XCTAssertEqual(session.configureCalls, 0)
    }

    // MARK: - Transport delegation while fallback is active

    func test_pause_delegatesToSpeechFallbackWhenActive() {
        let (player, synth, _) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Hello there.", languageCode: "en-US")
        player.pause()
        XCTAssertEqual(synth.pauseCalls, 1,
            "pause must drive the speech synthesizer when fallback owns playback")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isUsingSpeechFallback,
            "pausing while in fallback must NOT exit fallback mode")
    }

    func test_resume_delegatesToSpeechFallbackWhenActive() {
        let (player, synth, _) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Hello.", languageCode: "en-US")
        player.pause()
        player.resume()
        XCTAssertEqual(synth.continueCalls, 1,
            "resume must continue speech rather than touch AVQueuePlayer when fallback active")
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isUsingSpeechFallback)
        XCTAssertEqual(synth.spoken.count, 1,
            "resume must NOT re-enqueue a fresh utterance")
    }

    func test_stop_exitsFallbackMode() {
        let (player, synth, _) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Hello.", languageCode: "en-US")
        player.stop()
        XCTAssertEqual(synth.stopCalls, 1)
        XCTAssertFalse(player.isUsingSpeechFallback,
            "stop must clear the fallback flag so subsequent taps drive the MP3 path")
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - MP3 takeover stops fallback (no flicker / no broken state)

    func test_playSnapshotWithPlayableChapters_stopsFallback() {
        let (player, synth, _) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Holding the place for chapter 1.", languageCode: "en-US")
        XCTAssertTrue(player.isUsingSpeechFallback)

        let snap = snapshot(chapters: [playableChapter(index: 0)])
        player.play(snapshot: snap, startingAt: 0)

        XCTAssertFalse(player.isUsingSpeechFallback,
            "MP3 takeover must clear the fallback flag in the same turn")
        XCTAssertGreaterThanOrEqual(synth.stopCalls, 1,
            "the speech synthesizer must be stopped so MP3 and TTS never play simultaneously")
    }

    func test_playFallbackSpeech_doesNotStartMP3Player() {
        let (player, _, _) = makeAudioPlayer()
        player.playFallbackSpeech(text: "Hello.", languageCode: "en-US")
        // No snapshot was set — playableChapters should still be unavailable.
        XCTAssertNil(player.snapshot,
            "fallback must not synthesise a fake snapshot")
        XCTAssertEqual(player.currentChapterIndex, 0,
            "fallback must not advance the chapter index")
    }
}
#endif
