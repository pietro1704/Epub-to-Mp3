#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
@testable import EpubToMp3

/// Tests for the conversion-state tracking properties added to `AudioPlayer`:
/// `isConverting`, `conversionProgress`, `firstChapterReady`, and
/// `clearConversionState()` / `markFirstChapterReady()`.
///
/// These run on the macOS host — no device or audio session required.
final class AudioPlayerConversionStateTests: XCTestCase {

    // MARK: - Initial state

    @MainActor
    func testInitialConversionStateIsIdle() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isConverting,
            "isConverting must be false by default")
        XCTAssertNil(player.conversionProgress,
            "conversionProgress must be nil by default")
        XCTAssertFalse(player.firstChapterReady,
            "firstChapterReady must be false by default")
    }

    @MainActor
    func testIsLoadingInitiallyFalse() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isLoading,
            "isLoading must be false when neither isConverting nor firstChapterReady is set")
    }

    // MARK: - isLoading derived property

    /// isLoading is reserved for the initial playable chapter before playback.
    @MainActor
    func testIsLoadingTrueWhenConvertingAndNoFirstChapter() {
        let player = AudioPlayer()
        player.isConverting = true
        XCTAssertTrue(player.isLoading,
            "isLoading must be true when converting and firstChapterReady is false")
    }

    @MainActor
    func testIsLoadingFalseWhenFirstChapterReady() {
        let player = AudioPlayer()
        player.isConverting = true
        player.markFirstChapterReady()
        XCTAssertFalse(player.isLoading,
            "isLoading must be false once firstChapterReady is true, even during conversion")
    }

    /// A Listen tap must replace its play control immediately, including
    /// while the embedded runtime warms up and parses the book before the
    /// first chapter synthesis begins.
    @MainActor
    func testBeginPlaybackPreparationShowsLoadingBeforeAudioIsReady() {
        let player = AudioPlayer()

        player.beginPlaybackPreparation()

        XCTAssertTrue(player.isConverting)
        XCTAssertTrue(player.isLoading)
    }

    @MainActor
    func testLaterConversionDoesNotShowLoadingOverActivePlayback() {
        let player = AudioPlayer()
        player.isConverting = true
        player.testHook_setIsPlaying(true)

        XCTAssertFalse(player.isLoading,
            "Ongoing conversion must not replace transport controls while audio is playing")
    }

    // MARK: - markFirstChapterReady

    @MainActor
    func testMarkFirstChapterReadySetsFlag() {
        let player = AudioPlayer()
        XCTAssertFalse(player.firstChapterReady)
        player.markFirstChapterReady()
        XCTAssertTrue(player.firstChapterReady,
            "firstChapterReady must be true after markFirstChapterReady()")
    }

    @MainActor
    func testMarkFirstChapterReadyIsIdempotent() {
        let player = AudioPlayer()
        player.markFirstChapterReady()
        player.markFirstChapterReady()  // second call must not crash or toggle
        XCTAssertTrue(player.firstChapterReady)
    }

    /// Once firstChapterReady is true it must stay true (one-way latch).
    @MainActor
    func testFirstChapterReadyNeverGoesBackToFalse() {
        let player = AudioPlayer()
        player.markFirstChapterReady()
        // Simulating a new SSE event should not flip firstChapterReady back.
        player.isConverting = false
        XCTAssertTrue(player.firstChapterReady,
            "firstChapterReady is a latch — clearing isConverting must not reset it")
    }

    // MARK: - clearConversionState

    @MainActor
    func testClearConversionStateResetsAllFields() {
        let player = AudioPlayer()
        player.isConverting = true
        player.conversionProgress = 0.5
        player.markFirstChapterReady()

        player.clearConversionState()

        XCTAssertFalse(player.isConverting,
            "clearConversionState must reset isConverting")
        XCTAssertNil(player.conversionProgress,
            "clearConversionState must reset conversionProgress to nil")
        XCTAssertFalse(player.firstChapterReady,
            "clearConversionState must reset firstChapterReady")
    }

    @MainActor
    func testClearConversionStateIsIdempotentOnCleanPlayer() {
        let player = AudioPlayer()
        player.clearConversionState()   // should not crash on already-clean state
        XCTAssertFalse(player.isConverting)
        XCTAssertNil(player.conversionProgress)
        XCTAssertFalse(player.firstChapterReady)
    }

    // MARK: - MiniPlayerBar display logic (unit replica)

    /// Conversion done: isConverting=false, firstChapterReady=true.
    /// Bar should show normal play/pause.
    @MainActor
    func testMiniBarShowsPlayWhenConversionDone() {
        let player = AudioPlayer()
        player.isConverting = true
        player.markFirstChapterReady()
        player.isConverting = false
        XCTAssertFalse(player.isLoading,
            "Bar must show play/pause when conversion is done")
    }
}
#endif
