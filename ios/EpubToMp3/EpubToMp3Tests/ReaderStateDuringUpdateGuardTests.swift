import XCTest

/// Source-level regression guard for a "Modifying state during view update"
/// SwiftUI runtime warning at `ReaderView.attributedPages(...)`.
///
/// `attributedPages` runs synchronously inside `body`'s `GeometryReader`
/// closure (the `pages` let-binding computation) — it is NOT a `.task`/
/// `.onChange` callback. Writing `@State private var
/// chapterTransitionDisplayPage` directly from there mutates state while
/// SwiftUI is still evaluating that same `body`, which Apple documents as
/// undefined behavior (inconsistent view state, possible update loops).
///
/// The fix defers the write via `DispatchQueue.main.async`. Because
/// reproducing the runtime warning itself requires a live render pass (a UI
/// test), this unit test locks the SOURCE invariant so a future edit can't
/// reintroduce a synchronous `@State` write inside `attributedPages`.
/// Mirrors the existing `ReaderLivePagesGuardTests` source-inspection pattern.
final class ReaderStateDuringUpdateGuardTests: XCTestCase {

    private func readerSource() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ReaderView.swift not reachable in this test host (physical device) — source-inspection guard runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAttributedPagesDoesNotContainRawStateMutation() throws {
        let source = try readerSource()
        let start = try XCTUnwrap(
            source.range(of: "private func attributedPages(")?.lowerBound,
            "attributedPages(...) must exist"
        )
        let end = try XCTUnwrap(
            source.range(of: "private func bodyPlatformFont", range: start..<source.endIndex)?.lowerBound,
            "bodyPlatformFont marks the end of attributedPages(...)"
        )
        let lines = String(source[start..<end]).components(separatedBy: "\n")

        var foundAssignment = false
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "chapterTransitionDisplayPage = 0" {
            foundAssignment = true
            // Indentation-agnostic: the assignment must be preceded, within
            // a few lines, by the DispatchQueue.main.async deferral —
            // matching on trimmed content, not exact column, so a future
            // reflow/reindent of this block doesn't false-fail this guard.
            let precedingWindow = lines[max(0, i - 5)..<i].joined(separator: "\n")
            XCTAssertTrue(
                precedingWindow.contains("DispatchQueue.main.async"),
                "attributedPages(...) runs synchronously inside body's GeometryReader — a bare `chapterTransitionDisplayPage = 0` here re-triggers the \"Modifying state during view update\" warning. Wrap it in DispatchQueue.main.async."
            )
        }
        XCTAssertTrue(
            foundAssignment,
            "attributedPages(...) must reset chapterTransitionDisplayPage somewhere in its body."
        )
    }
}
