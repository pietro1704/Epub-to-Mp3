import XCTest

final class BookOpenViewPriorityTests: XCTestCase {
    func testBookOpenViewThreadsStartChapterIndexIntoRemoteBootstrapHelpers() throws {
        let source = try sourceFile(named: "BookOpenView.swift")

        XCTAssertTrue(
            source.contains("await self.waitForBackendThenBootstrap(startChapterIndex: startChapterIndex)"),
            "Remote bootstrap must thread the requested EPUB zero-based chapter into waitForBackendThenBootstrap instead of dropping it."
        )
        XCTAssertTrue(
            source.contains("private func waitForBackendThenBootstrap(startChapterIndex: Int) async"),
            "waitForBackendThenBootstrap must accept the requested EPUB zero-based chapter index."
        )
        XCTAssertTrue(
            source.contains("await bootstrapAudio(client: client, startChapterIndex: startChapterIndex)"),
            "Once the backend client becomes available, the requested chapter must continue into bootstrapAudio."
        )
        XCTAssertTrue(
            source.contains("private func bootstrapAudio(client: APIClient, startChapterIndex: Int) async"),
            "bootstrapAudio must accept the requested EPUB zero-based chapter index."
        )
    }

    func testBookOpenViewSubmitsPriorityChapterIndexToConvertOptions() throws {
        let source = try sourceFile(named: "BookOpenView.swift")

        XCTAssertTrue(
            source.contains("opts.priorityChapterIndex = startChapterIndex"),
            "Remote conversion submission must persist the requested EPUB zero-based chapter as the backend priority hint."
        )
    }

    func testApiClientConvertOptionsExposesPriorityChapterIndex() throws {
        let source = try apiClientSource()

        XCTAssertTrue(
            source.contains("var priorityChapterIndex: Int? = nil"),
            "ConvertOptions must expose an optional priorityChapterIndex field for remote on-demand streaming prioritization."
        )
        XCTAssertTrue(
            source.contains("appendField(name: \"priority_chapter_index\", value: String(priorityChapterIndex))"),
            "submitConversion must serialize priority_chapter_index when the caller provides it."
        )
    }

    func testInstantReaderForwardsSubsequentSnapshotsIntoMountedPlayer() throws {
        let source = try sourceFile(named: "InstantReaderView.swift")

        XCTAssertTrue(
            source.contains(".compatOnChange(of: snapshot) { updatedSnapshot in"),
            "InstantReaderView must observe snapshot changes after the first playable chapter appears."
        )
        XCTAssertTrue(
            source.contains("player.updateSnapshot(updatedSnapshot)"),
            "Mounted remote audio must receive every later SSE snapshot so newly completed chapters append to the live queue."
        )
    }

    private func sourceFile(named name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/\(name)"),
            encoding: .utf8
        )
    }

    private func apiClientSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Services/APIClient.swift"),
            encoding: .utf8
        )
    }
}
