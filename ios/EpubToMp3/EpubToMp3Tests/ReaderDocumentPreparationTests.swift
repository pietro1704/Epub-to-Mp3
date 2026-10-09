import Foundation
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderDocumentPreparationTests: XCTestCase {
    func testPreparationRunsOffMainAndPreservesParserPayloadAndSource() async throws {
        let source = try EpubFixture.createWithChapter(chapterTitle: "Reader chapter",
            body: "Readable <b>source</b> text.", footnote: (reference: "#note1", text: "A note"))
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let expected = EpubFallbackParser.parse(url: source, bookId: "preparation")
        XCTAssertFalse(expected.chapters.isEmpty)
        let actual = await EpubFallbackParser.parseAsync(url: source, bookId: "preparation") { url, id in
            XCTAssertFalse(Thread.isMainThread, "EPUB archive IO/extraction must not run on the UI thread")
            return EpubFallbackParser.parse(url: url, bookId: id)
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testBlockedPreparationDoesNotPreventMainActorHeartbeat() async throws {
        let source = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: source) }
        let heartbeat = expectation(description: "Main actor remains available")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let payload = await EpubFallbackParser.parseAsync(url: source, bookId: "blocked") { url, id in
            XCTAssertFalse(Thread.isMainThread)
            Task { @MainActor in
                heartbeat.fulfill()
                release.signal()
            }
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success,
                           "Main actor must release the worker before its deadline")
            return EpubFallbackParser.parse(url: url, bookId: id)
        }
        await fulfillment(of: [heartbeat], timeout: 1)
        XCTAssertFalse(payload.chapters.isEmpty)
    }

    #if os(macOS)
    func testMacAdapterKeepsIdenticalPreparedContent() async throws {
        let source = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: source) }
        let expected = await EpubFallbackParser.parseAsync(url: source, bookId: "mac")
        let actual = try await MacEpubParser.parse(at: source, bookId: "mac")
        XCTAssertEqual(actual, expected)
    }
    #endif
}
