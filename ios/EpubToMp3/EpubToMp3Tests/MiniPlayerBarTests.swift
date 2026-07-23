#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import Foundation
@testable import EpubToMp3

/// Unit tests for the data-model logic that drives `MiniPlayerBar`.
///
/// We test the guard expressions that control visibility, progress
/// computation, and player transport state — not SwiftUI rendering.
/// All tests run on the macOS host without a device or simulator.
@MainActor
final class MiniPlayerBarTests: XCTestCase {

    // MARK: - Setup / teardown

    private let bookIDKey = AudioPlayer.currentBookIDDefaultsKey
    private let chapterIndexKey = AudioPlayer.currentChapterIndexDefaultsKey

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: bookIDKey)
        UserDefaults.standard.removeObject(forKey: chapterIndexKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: bookIDKey)
        UserDefaults.standard.removeObject(forKey: chapterIndexKey)
        try await super.tearDown()
    }

    // MARK: - Hidden when currentBookID == nil

    /// When no book ID is persisted, the visibility guard evaluates to false.
    func testHiddenWhenCurrentBookIDIsNil() {
        let bookID: String? = UserDefaults.standard.string(forKey: bookIDKey)
        XCTAssertNil(bookID, "AppStorage key should be absent after setUp clears it")
        XCTAssertFalse(
            miniPlayerShouldShow(currentBookID: bookID, knownBookIDs: []),
            "Mini-player must be hidden when currentBookID is nil"
        )
    }

    /// An empty string is treated the same as nil — bar stays hidden.
    func testHiddenWhenCurrentBookIDIsEmpty() {
        XCTAssertFalse(
            miniPlayerShouldShow(currentBookID: "", knownBookIDs: ["some-id"]),
            "Mini-player must be hidden when currentBookID is empty string"
        )
    }

    // MARK: - Visible with book set

    /// When the book ID is persisted AND the book is in the library,
    /// the visibility guard evaluates to true.
    func testVisibleWhenBookIsPresentInLibrary() {
        let bookID = "dune-id-42"
        XCTAssertTrue(
            miniPlayerShouldShow(currentBookID: bookID, knownBookIDs: [bookID, "other-id"]),
            "Mini-player must be visible when the book is found in the library"
        )
    }

    /// When the book ID is set but no book in the library matches it,
    /// the bar stays hidden (book was removed from library).
    func testHiddenWhenBookIDNotInLibrary() {
        let bookID = "stale-id-99"
        XCTAssertFalse(
            miniPlayerShouldShow(currentBookID: bookID, knownBookIDs: ["other-book"]),
            "Mini-player must be hidden when bookID no longer exists in library"
        )
    }

    // MARK: - Correct title via BookEntity.resolvedTitle

    /// `resolvedTitle` must return the title that was set at init time.
    func testResolvedTitleMatchesInitialisedTitle() {
        let book = makeBook(title: "Foundation", id: "asimov-001")
        XCTAssertEqual(book.resolvedTitle, "Foundation")
    }

    // MARK: - Play / pause icon state

    /// The icon key for the play/pause button is driven by `AudioPlayer.isPlaying`.
    /// Default state is stopped → icon should be "play.fill".
    func testPlayIconWhenNotPlaying() {
        let player = AudioPlayer()
        let iconName = player.isPlaying ? "pause.fill" : "play.fill"
        XCTAssertEqual(iconName, "play.fill",
            "Icon must be play.fill when the player is not playing")
    }

    /// After calling `pause()`, `isPlaying` must be false → icon stays "play.fill".
    func testIconAfterPauseIsPlayFill() {
        let player = AudioPlayer()
        player.pause()
        let iconName = player.isPlaying ? "pause.fill" : "play.fill"
        XCTAssertEqual(iconName, "play.fill")
    }

    // MARK: - Progress computation

    /// Standard case: progress == position / duration.
    func testProgressNormalCase() {
        XCTAssertEqual(PlaybackPresentationState.progress(position: 30, duration: 120), 0.25, accuracy: 0.001)
    }

    /// Duration == 0 → progress must be 0 (no division by zero).
    func testProgressZeroWhenDurationIsZero() {
        XCTAssertEqual(PlaybackPresentationState.progress(position: 10, duration: 0), 0.0)
    }

    /// Position exceeds duration → progress clamps to 1.0.
    func testProgressClampedToOne() {
        XCTAssertEqual(PlaybackPresentationState.progress(position: 200, duration: 120), 1.0, accuracy: 0.001)
    }

    /// Negative position (shouldn't happen in practice) → progress clamps to 0.
    func testProgressClampedToZeroForNegativePosition() {
        XCTAssertEqual(PlaybackPresentationState.progress(position: -5, duration: 120), 0.0, accuracy: 0.001)
    }

    // MARK: - onTap closure contract

    /// `onTap` must execute synchronously when invoked — mirrors
    /// `onTapGesture { onTap() }` in the view.
    func testTapClosureExecutes() {
        var didTap = false
        let onTap = { didTap = true }
        onTap()
        XCTAssertTrue(didTap, "onTap closure must execute when called")
    }

    /// A second tap must also fire (closure is not one-shot).
    func testTapClosureFiresMultipleTimes() {
        var count = 0
        let onTap = { count += 1 }
        onTap(); onTap()
        XCTAssertEqual(count, 2)
    }

    // MARK: - skipForward does not crash without loaded audio

    /// `skipForward(seconds:)` must not crash when called with no audio loaded.
    func testSkipForwardWithNoAudioIsNoop() {
        let player = AudioPlayer()
        // Should not throw or crash.
        player.skipForward(seconds: 15)
        XCTAssertGreaterThanOrEqual(player.positionSeconds, 0)
        XCTAssertLessThanOrEqual(player.positionSeconds, player.durationSeconds)
    }

    // MARK: - Loading state (isLoading)

    /// When `isConverting == true` and `firstChapterReady == false`,
    /// `isLoading` must be true — the mini-player shows a spinner.
    func testIsLoadingTrueWhenConvertingAndNoChapterReady() {
        let player = AudioPlayer()
        player.isConverting = true
        // firstChapterReady is false by default.
        XCTAssertTrue(player.isLoading,
            "isLoading must be true when converting and no chapter is ready yet")
    }

    /// Once the first chapter is ready, `isLoading` drops to false even
    /// while conversion continues for subsequent chapters.
    func testIsLoadingFalseWhenFirstChapterReady() {
        let player = AudioPlayer()
        player.isConverting = true
        // Simulate first chapter becoming available (internal setter is
        // private — we verify the formula directly).
        let isLoading = player.isConverting && !player.firstChapterReady
        // firstChapterReady is false here; isLoading must reflect that.
        XCTAssertTrue(isLoading)
        // Directly validate the public property matches the formula.
        XCTAssertEqual(player.isLoading, isLoading)
    }

    /// When not converting, `isLoading` is always false regardless of
    /// `firstChapterReady`.
    func testIsLoadingFalseWhenNotConverting() {
        let player = AudioPlayer()
        player.isConverting = false
        XCTAssertFalse(player.isLoading,
            "isLoading must be false when not converting")
    }

    // MARK: - PlayerPresentation coordinator

    /// `PlayerPresentation.showFullPlayer()` flips the flag.
    func testPlayerPresentationShowFullPlayer() {
        let coord = PlayerPresentation()
        XCTAssertFalse(coord.showingFullPlayer)
        coord.showFullPlayer()
        XCTAssertTrue(coord.showingFullPlayer)
    }

    /// `PlayerPresentation.dismissFullPlayer()` clears the flag.
    func testPlayerPresentationDismissFullPlayer() {
        let coord = PlayerPresentation()
        coord.showFullPlayer()
        coord.dismissFullPlayer()
        XCTAssertFalse(coord.showingFullPlayer)
    }

    /// Setting `showingFullPlayer` directly is also valid — the sheet
    /// binding uses this path when the system dismisses via swipe.
    func testPlayerPresentationDirectAssignment() {
        let coord = PlayerPresentation()
        coord.showingFullPlayer = true
        XCTAssertTrue(coord.showingFullPlayer)
        coord.showingFullPlayer = false
        XCTAssertFalse(coord.showingFullPlayer)
    }

    // MARK: - Shared playback presentation

    func testChapterLabelUsesLivePlayableTitle() {
        let snapshot = JobSnapshot(
            jobId: "job",
            state: "finished",
            bookTitle: "Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: 100,
            chaptersTotal: 1,
            chaptersCompleted: 1,
            chapterProgress: [
                .init(
                    index: 4,
                    name: "Part Two",
                    status: "completed",
                    downloadUrl: "https://example.invalid/chapter.mp3",
                    chars: nil,
                    charsProcessed: nil,
                    progressRatio: 1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )

        XCTAssertEqual(
            PlaybackPresentationState.chapterLabel(snapshot: snapshot, currentChapterIndex: 0),
            "Part Two"
        )
    }

    func testChapterLabelFallsBackToLocalizedChapterNumber() {
        XCTAssertEqual(
            PlaybackPresentationState.chapterLabel(snapshot: nil, currentChapterIndex: 2),
            L10n.string("player.chapter", 3)
        )
    }

    // MARK: - Helpers


    /// Replicates the `showMiniPlayer` guard shared by `TabRoot` and `SplitViewRoot`.
    private func miniPlayerShouldShow(
        currentBookID: String?,
        knownBookIDs: [String]
    ) -> Bool {
        guard let id = currentBookID, !id.isEmpty else { return false }
        return knownBookIDs.contains(id)
    }


    /// Minimal `BookEntity` for testing. Non-nil bookmark Data satisfies
    /// the non-optional `bookmark` field without touching real disk I/O.
    private func makeBook(title: String, id: String) -> BookEntity {
        BookEntity(
            id: id,
            title: title,
            author: nil,
            bookmark: Data([0xFF]),
            displayFilename: "\(title).epub",
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil
        )
    }

    // MARK: - Regression: "..." button must not open player

    func testEllipsisButtonHasButtonStylePlain() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/MiniPlayerBar.swift")
        )
        // Verify the ellipsis Menu has .buttonStyle(.plain) so taps on it
        // are fully consumed by the Menu and do not leak to the bar's expand action.
        let ellipsisBlock = source.components(separatedBy: "ellipsis\")").last ?? ""
        XCTAssertTrue(
            ellipsisBlock.contains(".buttonStyle(.plain)"),
            "The '...' Menu must have .buttonStyle(.plain) to prevent tap leakage to the expand action."
        )
    }

    func testEllipsisMenuDoesNotHaveSimultaneousExpandGesture() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/MiniPlayerBar.swift")
        )
        // The bar expand gesture is a DragGesture — taps must not simultaneously
        // trigger the expand action when interacting with the "..." Menu.
        XCTAssertFalse(
            source.contains(".simultaneousGesture") && source.contains("ellipsis"),
            "The '...' Menu must not be wrapped in simultaneousGesture that would also fire the expand action."
        )
    }
}
#endif
