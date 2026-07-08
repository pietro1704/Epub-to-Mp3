import XCTest

final class InstantReaderAudioPrefetchTests: XCTestCase {
    func testInstantReaderDoesNotAutoPrefetchAudioOnAppearOrChapterChange() throws {
        let source = try instantReaderSource()

        XCTAssertFalse(
            source.contains("cacheManager.prefetchNext(2, from: newIndex)"),
            "InstantReaderView must not prefetch the next chapters automatically on chapter change; audio downloads should follow explicit user intent."
        )
        XCTAssertFalse(
            source.contains("cacheManager.prefetchNext(2, from: currentChapterIndex)"),
            "InstantReaderView must not prefetch the next chapters automatically on appear; opening the reader must stay download-silent."
        )
    }

    private func instantReaderSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
    }
}
