#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class MacBookDownloadActionTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var enqueued: [String] = []
    private var loaded: [String] = []
    private var alerts = 0

    override func setUp() {
        super.setUp()
        suite = "MacBookDownload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        enqueued = []
        loaded = []
        alerts = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func book(id: String = "book-a", title: String = "Shared title", lastJobId: String?) -> BookEntity {
        BookEntity(id: id, title: title, bookmark: Data([1]), displayFilename: "\(id).epub",
                   addedAt: .distantPast, lastJobId: lastJobId)
    }

    private func snapshot(jobID: String, title: String = "Shared title", playable: Bool = true) -> JobSnapshot {
        JobSnapshot(jobId: jobID, state: "finished", bookTitle: title, bookAuthor: nil, coverUrl: nil,
            coverMimeType: nil, engine: nil, voice: nil, language: nil, progressPercent: 100,
            chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [.init(index: 0, name: "Chapter", status: "completed",
                downloadUrl: playable ? "file:///tmp/\(jobID)/chapter.mp3" : nil, chars: 10, charsProcessed: 10,
                progressRatio: 1, durationSeconds: 5, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
    }

    private func library(_ books: [BookEntity]) throws -> LibraryStore {
        defaults.set(try JSONEncoder().encode(books), forKey: "library")
        return LibraryStore(defaults: defaults, defaultsKey: "library")
    }

    private func action(library: LibraryStore, current: JobSnapshot? = nil,
                        owner: (bookID: String, jobID: String)? = nil,
                        persisted: [String: JobSnapshot] = [:],
                        onLoad: @escaping () -> Void = {}) -> MacBookDownloadAction {
        MacBookDownloadAction(
            library: library,
            currentSnapshot: { current },
            streamingOwner: { owner },
            presentUnavailable: { [unowned self] in self.alerts += 1 },
            loadSnapshot: { [unowned self] jobID in
                self.loaded.append(jobID)
                onLoad()
                return persisted[jobID]
            },
            enqueue: { [unowned self] snapshot in self.enqueued.append(snapshot.jobId) })
    }

    func testBookWithLastJobEnqueuesItsPersistedSnapshot() async throws {
        let store = try library([book(lastJobId: "job-a")])
        let enqueuedAny = await action(library: store, persisted: ["job-a": snapshot(jobID: "job-a")])
            .download(bookID: "book-a")
        XCTAssertTrue(enqueuedAny)
        XCTAssertEqual(loaded, ["job-a"])
        XCTAssertEqual(enqueued, ["job-a"])
        XCTAssertEqual(alerts, 0)
    }

    func testPlayerSnapshotMatchingOnlyByTitleIsNeverEnqueued() async throws {
        let other = snapshot(jobID: "other-book-job")
        let unconverted = try library([book(lastJobId: nil)])
        let withoutJob = await action(library: unconverted, current: other).download(bookID: "book-a")
        XCTAssertFalse(withoutJob)
        XCTAssertEqual(enqueued, [])
        XCTAssertEqual(alerts, 1, "A same-title player snapshot must not stand in for a missing conversion")

        let converted = try library([book(lastJobId: "job-a")])
        let withJob = await action(library: converted, current: other,
                                   owner: (bookID: "another-book", jobID: "other-book-job"),
                                   persisted: ["job-a": snapshot(jobID: "job-a")]).download(bookID: "book-a")
        XCTAssertTrue(withJob)
        XCTAssertEqual(enqueued, ["job-a"], "The book's own job is enqueued, not the same-title player job")
    }

    func testLiveStreamingSnapshotOwnedByTheBookIsEnqueuedWithoutLoading() async throws {
        let store = try library([book(lastJobId: nil)])
        let live = snapshot(jobID: "live-job")
        let result = await action(library: store, current: live,
                                  owner: (bookID: "book-a", jobID: "live-job")).download(bookID: "book-a")
        XCTAssertTrue(result)
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(enqueued, ["live-job"])
    }

    func testMissingOrUnplayableSnapshotShowsTheAlert() async throws {
        let store = try library([book(lastJobId: "job-a")])
        let missing = await action(library: store).download(bookID: "book-a")
        let unplayable = await action(library: store, persisted: ["job-a": snapshot(jobID: "job-a", playable: false)])
            .download(bookID: "book-a")
        let mismatched = await action(library: store, persisted: ["job-a": snapshot(jobID: "job-b")])
            .download(bookID: "book-a")
        XCTAssertFalse(missing || unplayable || mismatched)
        XCTAssertEqual(enqueued, [])
        XCTAssertEqual(alerts, 3)
    }

    func testBookReconvertedWhileLoadingIsNotEnqueued() async throws {
        let original = book(lastJobId: "job-a")
        let store = try library([original])
        var reconverted = original
        reconverted.lastJobId = "job-b"
        let result = await action(library: store, persisted: ["job-a": snapshot(jobID: "job-a")],
                                  onLoad: { store.update(reconverted) }).download(bookID: "book-a")
        XCTAssertFalse(result)
        XCTAssertEqual(enqueued, [])
        XCTAssertEqual(alerts, 0)
    }

    func testUnknownBookDoesNothing() async throws {
        let store = try library([book(lastJobId: "job-a")])
        let result = await action(library: store).download(bookID: "missing-book")
        XCTAssertFalse(result)
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(alerts, 0)
    }
}
#endif
