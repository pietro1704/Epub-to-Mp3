#if os(iOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderListeningSessionTests: XCTestCase {
    private struct OpenFailure: Error {}

    private func book(_ id: String) -> BookEntity {
        BookEntity(id: id, title: id, bookmark: Data([1]),
                   displayFilename: "\(id).epub", addedAt: Date())
    }

    func testConstructingSessionNeverOpensOrStartsPlayback() throws {
        let suite = "reader-listening-standby-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var openCount = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("Constructing a reader must not start conversion")
                throw OpenFailure()
            }, currentBookID: { "book" },
            openBook: { _ in openCount += 1; throw OpenFailure() },
            recordConversion: { _, _ in XCTFail("No conversion was requested") },
            reportFailure: { _ in XCTFail("No file open was requested") }
        )
        session.observePlayback()
        session.observePlayback()
        XCTAssertFalse(session.isListening(to: "book"))
        XCTAssertEqual(openCount, 0)
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isConverting)
    }

    func testCancellationRejectsLateFileOpenBeforeItTouchesThePlayer() async throws {
        try await assertPendingOpenIsRejected(replacesBook: false)
    }

    func testBookReplacementRejectsLateFileOpenBeforeItTouchesThePlayer() async throws {
        try await assertPendingOpenIsRejected(replacesBook: true)
    }

    private func assertPendingOpenIsRejected(replacesBook: Bool) async throws {
        let suite = "reader-listening-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let started = expectation(description: "The original book open is pending")
        var pending: CheckedContinuation<URL, Error>?
        var activeBookID = "original"
        var conversions = 0
        var failures = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                conversions += 1
                throw OpenFailure()
            }, currentBookID: { activeBookID },
            openBook: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }, recordConversion: { _, _ in XCTFail("A retired open has no artifacts") },
            reportFailure: { _ in failures += 1 }
        )
        session.start(book: book("original"), priority: 0, pageRatio: nil,
                      catalog: [(index: 0, title: "Original chapter")],
                      conversionOptions: AppSettings(defaults: defaults).conversionOptions,
                      presentsFullPlayer: false)
        await fulfillment(of: [started], timeout: 2)
        if replacesBook { activeBookID = "replacement" }
        else { session.cancel() }
        let continuation = try XCTUnwrap(pending)
        continuation.resume(returning: URL(fileURLWithPath: "/unused/original.epub"))
        await session.waitForCompletion()
        XCTAssertEqual(conversions, 0)
        XCTAssertEqual(failures, 0)
        XCTAssertFalse(session.isListening(to: "original"))
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isConverting)
    }

    func testCurrentOpenFailureReportsWithoutInstallingAPlaybackSession() async throws {
        let suite = "reader-listening-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var failures = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("A failed file open must not reach Rust")
                throw OpenFailure()
            }, currentBookID: { "missing" }, openBook: { _ in throw OpenFailure() },
            recordConversion: { _, _ in XCTFail("A failed open has no artifacts") },
            reportFailure: { _ in failures += 1 }
        )
        session.start(book: book("missing"), priority: 0, pageRatio: nil, catalog: [],
                      conversionOptions: AppSettings(defaults: defaults).conversionOptions,
                      presentsFullPlayer: false)
        await session.waitForCompletion()
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(session.isListening(to: "missing"))
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isConverting)
    }
}
#endif
