#if os(iOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderBookLoadSessionTests: XCTestCase {
    private struct OpenFailure: LocalizedError {
        var errorDescription: String? { "The source is unavailable" }
    }

    @MainActor
    private final class Fixture {
        let document: ReaderBookDocument
        let session: ReaderBookLoadSession
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        var events: [String] = []
        var urls: [URL] = []

        init(readFulltext: @escaping @Sendable (String) async -> EbookFulltext? = { _ in nil },
             openBook: @escaping (String) async throws -> URL) throws {
            suite = "reader-load-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            document = ReaderBookDocument(book: BookEntity(
                id: suite, title: "Original", bookmark: Data([1]),
                displayFilename: "original.pdf", addedAt: Date(), fileType: .pdf
            ))
            let settings = AppSettings(defaults: defaults)
            let store = PreparedReaderChapterStore(directory: directory)
            let renderer = PreparedChapterRenderer.shared
            let prepared = ReaderPreparedPresentation(
                document: document, settings: settings, renderer: renderer, store: store,
                stageObserver: nil, viewportIsCommitted: { false }, textIsLaidOut: { false },
                send: { _ in XCTFail("PDF loading must not mount an EPUB projection") }
            )
            // The weak recorder is wired after initialization without making
            // a session -> recorder -> session ownership cycle.
            let recorder = Recorder()
            session = ReaderBookLoadSession(
                document: document, settings: settings, renderer: renderer, store: store,
                preparedPresentation: prepared, readFulltext: readFulltext,
                writeFulltext: { _, _, _, _ in XCTFail("Retired loads and PDF opens must not persist EPUB fulltext") },
                openBook: openBook, stageObserver: nil,
                send: { [recorder] in recorder.record($0) }
            )
            recorder.fixture = self
        }

        func cleanup() {
            session.cancel()
            if let id = document.activeBookOpenJourneyID { _ = LatencyObservationStore.shared.cancel(id) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private final class Recorder {
        weak var fixture: Fixture?
        func record(_ event: ReaderBookLoadSession.Event) {
            switch event {
            case .cancelJourney: fixture?.events.append("cancelJourney")
            case .showLoading: fixture?.events.append("showLoading")
            case .hideLoading: fixture?.events.append("hideLoading")
            case .loadFixture: XCTFail("Unit tests must exercise the real loading session")
            case let .showPDF(url):
                fixture?.events.append("showPDF")
                fixture?.urls.append(url)
            case let .failure(message):
                fixture?.events.append("failure")
                XCTAssertEqual(message, "The source is unavailable")
            }
        }
    }

    func testStandbyDoesNotOpenOrPresentAnything() throws {
        let fixture = try Fixture { _ in XCTFail("Standby must not access a source"); throw OpenFailure() }
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertNil(fixture.document.loadGenerationID)
    }

    func testCurrentPDFOpensExactSourceBeforeHidingCover() async throws {
        let url = URL(fileURLWithPath: "/unused/current.pdf")
        let fixture = try Fixture { _ in url }
        defer { fixture.cleanup() }
        fixture.session.loadBook()
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.events, ["cancelJourney", "showLoading", "showPDF", "hideLoading"])
        XCTAssertEqual(fixture.urls, [url])
    }

    func testCurrentFailureIsTerminalWithoutPresentingPDF() async throws {
        let fixture = try Fixture { _ in throw OpenFailure() }
        defer { fixture.cleanup() }
        fixture.session.loadBook()
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.events, ["cancelJourney", "showLoading", "failure"])
        XCTAssertTrue(fixture.urls.isEmpty)
    }

    func testCancelledOpenCannotMountItsLatePDF() async throws {
        try await assertLateOpenRejected(replaceBook: false, fails: false)
    }

    func testReplacedBookCannotMountTheOriginalPDF() async throws {
        try await assertLateOpenRejected(replaceBook: true, fails: false)
    }

    func testRetiredFailureCannotReplaceTheNewBooksLoadingState() async throws {
        try await assertLateOpenRejected(replaceBook: true, fails: true)
    }

    private actor PendingFulltext {
        private var continuation: CheckedContinuation<EbookFulltext?, Never>?
        let started = XCTestExpectation(description: "The original cached read is pending")
        func read() async -> EbookFulltext? {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func release(_ payload: EbookFulltext) {
            continuation?.resume(returning: payload)
            continuation = nil
        }
    }

    func testCancelledAndReplacedCachedReadsCannotPublishOrPersistTheirLatePayload() async throws {
        for replaceBook in [false, true] {
            let pending = PendingFulltext()
            let fixture = try Fixture(readFulltext: { _ in await pending.read() }, openBook: { _ in
                XCTFail("The retired cached read must not access a source")
                throw OpenFailure()
            })
            defer { fixture.cleanup() }
            fixture.session.loadBook()
            await fulfillment(of: [pending.started], timeout: 2)
            if replaceBook {
                fixture.document.book = BookEntity(id: "replacement", title: "Replacement", bookmark: Data([2]),
                    displayFilename: "replacement.pdf", addedAt: Date(), fileType: .pdf)
            } else {
                fixture.session.cancel()
            }
            let payload = EbookFulltext(jobId: fixture.document.book.id, bookTitle: "Late payload", bookAuthor: nil,
                chapters: [.init(index: 1, name: "Authored chapter", text: "Late readable text", html: nil,
                    css: nil, charCount: nil, segments: nil)])
            await pending.release(payload)
            await fixture.session.waitForCompletion()
            XCTAssertEqual(fixture.events, ["cancelJourney", "showLoading"])
            XCTAssertNil(fixture.document.fulltext)
            XCTAssertTrue(fixture.urls.isEmpty)
        }
    }

    private func assertLateOpenRejected(replaceBook: Bool, fails: Bool) async throws {
        let opened = expectation(description: "Original file access is pending")
        var pending: CheckedContinuation<URL, Error>?
        let fixture = try Fixture { _ in
            try await withCheckedThrowingContinuation {
                pending = $0
                opened.fulfill()
            }
        }
        defer { fixture.cleanup() }
        fixture.session.loadBook()
        await fulfillment(of: [opened], timeout: 2)
        if replaceBook {
            fixture.document.book = BookEntity(
                id: "replacement", title: "Replacement", bookmark: Data([2]),
                displayFilename: "replacement.pdf", addedAt: Date(), fileType: .pdf
            )
        } else {
            fixture.session.cancel()
        }
        let continuation = try XCTUnwrap(pending)
        if fails { continuation.resume(throwing: OpenFailure()) }
        else { continuation.resume(returning: URL(fileURLWithPath: "/unused/original.pdf")) }
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.events, ["cancelJourney", "showLoading"])
        XCTAssertTrue(fixture.urls.isEmpty)
    }
}
#endif
