import XCTest

/// Source-level regression guard: the lyric position-follow loops in
/// `FullPlayerSheet` (modernBody + legacyBody) must only run while
/// `showLyricsOverlay` is true.
///
/// `player.position` ticks at ~4 Hz; writing `@State lyricSentenceId` on
/// every tick re-evaluates the whole 1000+-line body even when the lyrics
/// overlay is closed and `currentLyricText` isn't rendered anywhere. The
/// fix gates the loop with `.task(id: showLyricsOverlay)` so the position
/// stream — and the state writes — only run while lyrics are visible.
/// Mirrors the existing `ReaderLivePagesGuardTests` source-inspection
/// pattern (verifying live behavior needs a UI test; this locks the
/// source invariant against regression).
final class FullPlayerSheetLyricLoopGuardTests: XCTestCase {

    private func fullPlayerSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("FullPlayerSheet.swift not reachable in this test host (physical device) — source-inspection guard runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBothPositionFollowLoopsAreGatedByShowLyricsOverlay() throws {
        let source = try fullPlayerSource()
        let gatedLoopCount = source.components(separatedBy: ".task(id: showLyricsOverlay) {").count - 1
        XCTAssertEqual(
            gatedLoopCount, 2,
            "Both modernBody and legacyBody must gate their `for await position in player.position` loop with .task(id: showLyricsOverlay) — found \(gatedLoopCount)."
        )
    }

    func testNoUngatedPositionFollowLoopRemains() throws {
        let source = try fullPlayerSource()
        // A bare `.task {` immediately followed by the position loop (no
        // `id:` gate) would reintroduce the 4 Hz whole-body invalidation.
        XCTAssertFalse(
            source.contains("""
            .task {
                        for await position in player.position {
            """),
            "The lyric position-follow loop must be gated by .task(id: showLyricsOverlay), not a plain unconditional .task."
        )
    }
}
