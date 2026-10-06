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

    /// isLoading = isConverting && !firstChapterReady
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

    @MainActor
    func testIsLoadingFalseWhenNotConverting() {
        let player = AudioPlayer()
        player.isConverting = false
        XCTAssertFalse(player.isLoading)
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

    // MARK: - conversionProgress bounds

    @MainActor
    func testConversionProgressStoresArbitraryValue() {
        let player = AudioPlayer()
        player.conversionProgress = 0.75
        XCTAssertEqual(player.conversionProgress ?? -1, 0.75, accuracy: 0.001)
    }

    @MainActor
    func testConversionProgressCanBeZero() {
        let player = AudioPlayer()
        player.conversionProgress = 0.0
        XCTAssertEqual(player.conversionProgress ?? -1, 0.0, accuracy: 0.001)
    }

    @MainActor
    func testConversionProgressCanBeOne() {
        let player = AudioPlayer()
        player.conversionProgress = 1.0
        XCTAssertEqual(player.conversionProgress ?? -1, 1.0, accuracy: 0.001)
    }

    // MARK: - MiniPlayerBar display logic (unit replica)

    /// The bar should show a spinner (not play/pause) when converting
    /// and the first chapter has not arrived yet.
    @MainActor
    func testMiniBarShowsSpinnerWhenConvertingNoFirstChapter() {
        let player = AudioPlayer()
        player.isConverting = true
        let showSpinner = player.isConverting && !player.firstChapterReady
        XCTAssertTrue(showSpinner,
            "MiniPlayerBar must show spinner while isConverting && !firstChapterReady")
    }

    /// After the first chapter lands the bar switches to play/pause,
    /// regardless of isConverting still being true (background chapters).
    @MainActor
    func testMiniBarShowsPlayAfterFirstChapterReady() {
        let player = AudioPlayer()
        player.isConverting = true
        player.markFirstChapterReady()
        let showSpinner = player.isConverting && !player.firstChapterReady
        XCTAssertFalse(showSpinner,
            "MiniPlayerBar must switch to play/pause once firstChapterReady is true")
    }

    /// Conversion done: isConverting=false, firstChapterReady=true.
    /// Bar should show normal play/pause.
    @MainActor
    func testMiniBarShowsPlayWhenConversionDone() {
        let player = AudioPlayer()
        player.isConverting = true
        player.markFirstChapterReady()
        player.isConverting = false
        let showSpinner = player.isConverting && !player.firstChapterReady
        XCTAssertFalse(showSpinner,
            "Bar must show play/pause when conversion is done")
    }

    // MARK: - Progress bar color logic (unit replica)

    /// While converting with known progress, the bar color key is "orange".
    @MainActor
    func testProgressBarUsesOrangeColorKeyDuringConversion() {
        let player = AudioPlayer()
        player.isConverting = true
        player.conversionProgress = 0.4
        let useOrange = player.isConverting && player.conversionProgress != nil
        XCTAssertTrue(useOrange,
            "Progress bar must use orange tint during active conversion with known progress")
    }

    /// After conversion completes, accent color is used.
    @MainActor
    func testProgressBarUsesAccentColorAfterConversion() {
        let player = AudioPlayer()
        player.isConverting = false
        let useOrange = player.isConverting && player.conversionProgress != nil
        XCTAssertFalse(useOrange,
            "Progress bar must use accent color when not converting")
    }
}
#endif
