#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Slice-4 tests: unified `playOrFallback` entry that the reader/UI
/// surfaces call when the user taps Play. It must route to MP3 when the
/// requested chapter has a playable `downloadUrl`, fall back to the
/// accessibility speech path when only the chapter fulltext is available,
/// and stay a no-op when neither is — without ever flickering between
/// the two transports.
///
/// Reuses the `FakeSynthesizer` / `FakeSpeechAudioSession` fakes from
/// `SpeechFallbackPlayerTests`; injects the fallback via the AudioPlayer
/// init so no real AV or audio-session call ever fires.
@MainActor
final class AudioPlayerFulltextFallbackTests: XCTestCase {

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

    private func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "slice4-job",
            state: "running",
            bookTitle: "Slice 4",
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

    // MARK: - MP3 is primary

    func test_playOrFallback_routesMP3_whenChapterIsPlayable() {
        let (player, synth, session) = makeAudioPlayer()
        let snap = snapshot(chapters: [playableChapter(index: 0)])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 0,
            chapterText: "Some chapter text that should NOT be spoken because MP3 is ready.",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedAudio,
            "MP3 path is primary — speech fallback must never preempt a playable chapter")
        XCTAssertFalse(player.isUsingSpeechFallback,
            "fallback flag must stay false when MP3 takes the route")
        XCTAssertEqual(synth.spoken.count, 0,
            "speech synthesizer must remain untouched when MP3 is ready")
        XCTAssertEqual(session.configureCalls, 0,
            "speech audio session must not be configured for an MP3 route")
        XCTAssertEqual(player.currentChapterIndex, 0)
    }

    func test_playOrFallback_routesMP3_evenWhenTextIsEmpty() {
        let (player, synth, _) = makeAudioPlayer()
        let snap = snapshot(chapters: [playableChapter(index: 0)])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 0,
            chapterText: "",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedAudio,
            "MP3 path doesn't require chapter text — text is only the fallback input")
        XCTAssertEqual(synth.spoken.count, 0)
    }

    func test_playOrFallback_routesMP3_atRequestedIndex_whenMultiplePlayable() {
        let (player, _, _) = makeAudioPlayer()
        let snap = snapshot(chapters: [
            playableChapter(index: 0),
            playableChapter(index: 1),
            playableChapter(index: 2),
        ])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 2,
            chapterText: "ignored",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedAudio)
        XCTAssertEqual(player.currentChapterIndex, 2,
            "playOrFallback must translate the EPUB chapter index to the playable-list index used by play(snapshot:startingAt:)")
    }

    // MARK: - Speech fallback when MP3 not ready

    func test_playOrFallback_routesSpeech_whenChapterPending_andTextExists() {
        let (player, synth, session) = makeAudioPlayer()
        let snap = snapshot(chapters: [pendingChapter(index: 0)])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 0,
            chapterText: "Once upon a time.",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedSpeechFallback,
            "no playable URL ⇒ fallback should engage so the user gets immediate audio")
        XCTAssertTrue(player.isUsingSpeechFallback)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(synth.spoken.first?.speechString, "Once upon a time.")
        XCTAssertEqual(session.configureCalls, 1)
    }

    func test_playOrFallback_routesSpeech_whenRequestedChapterIsPending_andOtherChaptersPlayable() {
        let (player, synth, _) = makeAudioPlayer()
        // Chapter 0 finished; user asked for chapter 1 which is still pending.
        let snap = snapshot(chapters: [playableChapter(index: 0), pendingChapter(index: 1)])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 1,
            chapterText: "Chapter two body.",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedSpeechFallback,
            "even with some playable chapters, fallback must engage when THE REQUESTED chapter has no URL")
        XCTAssertEqual(synth.spoken.first?.speechString, "Chapter two body.")
    }

    func test_playOrFallback_routesSpeech_whenSnapshotNil_andTextExists() {
        let (player, synth, _) = makeAudioPlayer()
        let result = player.playOrFallback(
            snapshot: nil,
            chapterIndex: 0,
            chapterText: "Standalone chapter text.",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedSpeechFallback,
            "no snapshot ⇒ MP3 unavailable ⇒ fallback should engage if text exists")
        XCTAssertEqual(synth.spoken.count, 1)
    }

    func test_playOrFallback_propagatesLanguageCode_toSpeechFallback() {
        let (player, synth, _) = makeAudioPlayer()
        let result = player.playOrFallback(
            snapshot: nil,
            chapterIndex: 0,
            chapterText: "Era uma vez.",
            languageCode: "pt-BR"
        )
        XCTAssertEqual(result, .startedSpeechFallback)
        XCTAssertEqual(synth.spoken.first?.voice?.language, "pt-BR",
            "language code from the caller must reach the speech utterance so pt-BR books are not narrated in en-US")
    }

    // MARK: - No-op when neither route is viable

    func test_playOrFallback_returnsNoOp_whenChapterPending_andTextMissing() {
        let (player, synth, session) = makeAudioPlayer()
        let snap = snapshot(chapters: [pendingChapter(index: 0)])
        let result = player.playOrFallback(
            snapshot: snap,
            chapterIndex: 0,
            chapterText: nil,
            languageCode: nil
        )
        XCTAssertEqual(result, .noOp,
            "neither MP3 nor text ⇒ caller learns nothing was started; UI must not flip to playing")
        XCTAssertFalse(player.isUsingSpeechFallback)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(synth.spoken.count, 0)
        XCTAssertEqual(session.configureCalls, 0)
    }

    func test_playOrFallback_returnsNoOp_whenSnapshotNil_andTextEmpty() {
        let (player, synth, _) = makeAudioPlayer()
        let result = player.playOrFallback(
            snapshot: nil,
            chapterIndex: 0,
            chapterText: "",
            languageCode: nil
        )
        XCTAssertEqual(result, .noOp)
        XCTAssertFalse(player.isUsingSpeechFallback)
        XCTAssertEqual(synth.spoken.count, 0)
    }

    func test_playOrFallback_returnsNoOp_whenTextIsWhitespaceOnly() {
        let (player, synth, _) = makeAudioPlayer()
        let result = player.playOrFallback(
            snapshot: nil,
            chapterIndex: 0,
            chapterText: "   \n\t  ",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .noOp,
            "whitespace-only text must not engage the fallback — the user would hear silence and the flag would lie")
        XCTAssertFalse(player.isUsingSpeechFallback)
        XCTAssertEqual(synth.spoken.count, 0)
    }

    // MARK: - No-flicker invariant: MP3 takeover from fallback

    func test_playOrFallback_mp3TakeoverFromActiveFallback_stopsFallback() {
        let (player, synth, _) = makeAudioPlayer()
        // First call: no MP3 yet → fallback engages.
        let pending = snapshot(chapters: [pendingChapter(index: 0)])
        _ = player.playOrFallback(
            snapshot: pending,
            chapterIndex: 0,
            chapterText: "Holding the place.",
            languageCode: "en-US"
        )
        XCTAssertTrue(player.isUsingSpeechFallback)

        // Second call: MP3 ready → must take over and cleanly stop the synth.
        let ready = snapshot(chapters: [playableChapter(index: 0)])
        let result = player.playOrFallback(
            snapshot: ready,
            chapterIndex: 0,
            chapterText: "Holding the place.",
            languageCode: "en-US"
        )
        XCTAssertEqual(result, .startedAudio)
        XCTAssertFalse(player.isUsingSpeechFallback,
            "MP3 takeover must clear the fallback flag in the same turn — no overlapping transports")
        XCTAssertGreaterThanOrEqual(synth.stopCalls, 1,
            "the synthesizer must be stopped so MP3 and TTS never play simultaneously")
    }
}
#endif
