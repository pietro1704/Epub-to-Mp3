import XCTest

/// Source-level regression guard for the "flicker to page 0" family of bugs.
///
/// Every `.compatOnChange` closure inside the paginated body captures a `pages`
/// let-binding from the GeometryReader render. During a concurrent re-render
/// that array can be momentarily empty/stale, so any page lookup that reads it
/// directly collapses to index 0 and snaps the reader to the top — the flicker
/// the user saw on a normal page turn, on chapter crossing, and (the missed
/// path) on audio auto-follow.
///
/// The fix funnels every such lookup through `livePages(fallback:)`, which
/// prefers the reference-type `paginationCache.pages` (always current). Because
/// exercising the real `UIPageViewController`/render race requires a UI test
/// (`ReaderFlickerUITests`), this unit test locks the SOURCE invariant so a
/// future edit can't reintroduce a raw-`pages` read on one of these paths.
final class ReaderLivePagesGuardTests: XCTestCase {

    /// This is a source-inspection guard: it reads ReaderView.swift off the
    /// build machine via `#filePath`. That path only exists on the host/
    /// simulator, not inside a physical-device test bundle — so on device the
    /// source is unreachable and the check is skipped (it runs in CI on the
    /// host, which is where the invariant is enforced). Mirrors the existing
    /// `MainReaderViewTests` source-inspection pattern.
    private func readerSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("EpubToMp3/Views/ReaderView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ReaderView.swift not reachable in this test host (physical device) — source-inspection guard runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testLivePagesHelperExists() throws {
        let source = try readerSource()
        XCTAssertTrue(
            source.contains("private func livePages(fallback: [NSAttributedString]) -> [NSAttributedString]"),
            "The centralised livePages(fallback:) helper must exist so every closure resolves the current page array the same way."
        )
        XCTAssertTrue(
            source.contains("paginationCache.pages.isEmpty ? fallback : paginationCache.pages"),
            "livePages(fallback:) must prefer the live paginationCache.pages and fall back to the captured array only when the cache is empty."
        )
    }

    func testAutoFollowUsesLivePagesNotRawCapturedArray() throws {
        let source = try readerSource()
        // The auto-follow closure must resolve pages through the helper and
        // must NOT feed the raw captured `pages` straight into the sentence
        // lookup (the historical miss that snapped the reader to page 0 mid
        // playback).
        XCTAssertTrue(
            source.contains("let followPages = livePages(fallback: pages)"),
            "Audio auto-follow must read from livePages(fallback:), not the raw captured pages array."
        )
        XCTAssertFalse(
            source.contains("pageIndexContaining(sentence: span, in: pages)"),
            "Auto-follow must not pass the raw captured `pages` to pageIndexContaining — use the live cache."
        )
    }

    func testSettingsReflowHandlersUseLivePages() throws {
        let source = try readerSource()
        // Font / line-spacing / margin / column-width changes repaginate the
        // chapter; syncPageToTextOffset must read the live array or it snaps to
        // page 0 during the reflow.
        XCTAssertFalse(
            source.contains("syncPageToTextOffset(in: pages) }"),
            "Settings-reflow handlers must call syncPageToTextOffset(in: livePages(fallback: pages)), not the raw captured array."
        )
        XCTAssertTrue(
            source.contains("syncPageToTextOffset(in: livePages(fallback: pages))"),
            "Settings-reflow handlers must route through livePages(fallback:)."
        )
    }
}
