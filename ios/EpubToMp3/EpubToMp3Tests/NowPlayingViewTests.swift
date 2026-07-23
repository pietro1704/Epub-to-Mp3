import XCTest
import SwiftUI
@testable import EpubToMp3

/// Smoke + persistence tests for `NowPlayingView`. The view branches on
/// the persisted `currentlyPlayingBookID` value, so we exercise the
/// branch via `UserDefaults` round-trips rather than rendering the
/// SwiftUI tree (calling `.body` on `@AppStorage`-driven views in a
/// unit-test host trips SwiftUI's "no live environment" trap).
final class NowPlayingViewTests: XCTestCase {

    // Use an isolated UserDefaults suite per test to avoid bleed between
    // suites and to stay clear of the host app's real preferences.
    private var defaults: UserDefaults!
    private let suite = "nowplaying.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Construction

    func testNowPlayingViewConstructsWithEmptyLibrary() {
        // The view should construct cleanly even when no book id is
        // persisted — that's the canonical empty-state launch path.
        _ = NowPlayingView()
        XCTAssertNil(defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
    }

    func testNowPlayingViewConstructsWithBrowseCallback() {
        // The empty-state CTA threads back to the hosting router via
        // `onBrowseLibrary`. Make sure the optional closure binds.
        var fired = false
        _ = NowPlayingView(onBrowseLibrary: { fired = true })
        // We can't actually invoke the body's button from a unit test,
        // but we can prove the wiring compiles + initialises.
        XCTAssertFalse(fired)
    }

    // MARK: - Persistence round-trip

    func testSetCurrentlyPlayingPersistsBookAndChapter() {
        NowPlayingView.setCurrentlyPlaying(
            bookID: "book-123",
            chapterIndex: 4,
            defaults: defaults
        )
        XCTAssertEqual(
            defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
            "book-123"
        )
        XCTAssertEqual(
            defaults.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey),
            4
        )
    }

    func testSetCurrentlyPlayingClearsBookWhenNil() {
        // Seed a prior value, then clear.
        defaults.set("seed", forKey: AudioPlayer.currentBookIDDefaultsKey)
        defaults.set(7, forKey: AudioPlayer.currentChapterIndexDefaultsKey)

        NowPlayingView.setCurrentlyPlaying(
            bookID: nil,
            chapterIndex: 99,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
        XCTAssertNil(defaults.object(forKey: AudioPlayer.currentChapterIndexDefaultsKey))
    }

    func testSetCurrentlyPlayingClampsNegativeChapterIndexToZero() {
        // Defensive: a stale `currentChapterIndex` from a prior bug
        // should never round-trip a negative value into UserDefaults.
        NowPlayingView.setCurrentlyPlaying(
            bookID: "book-x",
            chapterIndex: -3,
            defaults: defaults
        )
        XCTAssertEqual(
            defaults.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey),
            0
        )
    }

    func testSetCurrentlyPlayingTreatsEmptyStringAsNil() {
        // Empty bookID is treated as "nothing playing" — used by the
        // auto-clear branch when the library no longer contains the
        // persisted id.
        defaults.set("seed", forKey: AudioPlayer.currentBookIDDefaultsKey)
        NowPlayingView.setCurrentlyPlaying(
            bookID: "",
            chapterIndex: 0,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
    }

    // MARK: - Widget "stale isPlaying" regression (bug fix)

    /// Regression for: the Now Playing widget showed a pause button even
    /// when nothing was actually playing. Root cause: `setCurrentlyPlaying`
    /// used to write `isPlaying: bookID != nil` to the App Group — i.e. it
    /// treated "a book is bound to the player" as "audio is playing", which
    /// is false the moment a book is merely opened (playback only starts on
    /// an explicit user action). Binding a book must never claim playback
    /// is active; only `AudioPlayer.updateNowPlayingInfo()` (driven by the
    /// real `isPlaying` flag) is allowed to assert that.
    func testSetCurrentlyPlayingNeverClaimsIsPlayingTrue() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/NowPlayingView.swift")
        )
        XCTAssertFalse(
            source.contains("isPlaying: bookID != nil"),
            "setCurrentlyPlaying must not infer isPlaying from whether a book id is set — that caused the widget to show a permanently-stale pause button."
        )
    }

    func testNowPlayingUsesJobSnapshotStubForPlayerReader() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/NowPlayingView.swift")
        )

        XCTAssertTrue(source.contains("private func makeSnapshot(for book: BookEntity) -> JobSnapshot?"),
                      "NowPlayingView should centralize its PlayerReader bootstrap through one snapshot builder.")
        XCTAssertTrue(source.contains("PlayerReaderView("),
                      "NowPlayingView must still route the populated branch into PlayerReaderView.")
        XCTAssertTrue(source.contains("guard let jobId = book.lastJobId else { return nil }"),
                      "The snapshot helper must no-op for books that never finished a conversion.")
    }

    // MARK: - Tab-routing contract

    /// `RootTab` raw values double as `TabView` selection tokens; they
    /// must stay stable across builds so SwiftUI's animation state
    /// machine doesn't reset every time the enum is reshuffled.
    /// As of the Apple Books-style library slice, Reader is no longer a
    /// tab — books are pushed from Library with an in-reader close X.
    /// Library is 0, Settings is 1, Convert is 2.
    func testRootTabRawValuesAreStable() {
        XCTAssertEqual(RootTab.library.rawValue, 0)
        XCTAssertEqual(RootTab.settings.rawValue, 1)
        XCTAssertEqual(RootTab.convert.rawValue, 2)
    }

    /// `SplitNavMode` should expose every destination required by the
    /// sidebar list. Now Playing was removed from the sidebar in the
    /// Music/Spotify player slice — the full player surfaces via sheet.
    func testSplitNavModeDoesNotIncludeNowPlaying() {
        XCTAssertEqual(SplitNavMode.allCases.first, .reader)
        XCTAssertFalse(
            SplitNavMode.allCases.contains(where: { $0.rawValue == "nowPlaying" }),
            "nowPlaying must not be a sidebar destination — it is a sheet now."
        )
        XCTAssertTrue(SplitNavMode.allCases.contains(.library))
        XCTAssertTrue(SplitNavMode.allCases.contains(.settings))
    }

    func testSplitNavModeProvidesSFSymbolForEveryDestination() {
        for mode in SplitNavMode.allCases {
            XCTAssertFalse(mode.systemImage.isEmpty,
                           "Sidebar would render a missing icon for \(mode).")
            XCTAssertFalse(mode.label.isEmpty)
        }
    }
}
