import Foundation
import XCTest
@testable import EpubToMp3

private actor MigrationGate {
    let entered = XCTestExpectation(description: "Migration is inside its work")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor StopCount {
    private(set) var value = 0
    func add() { value += 1 }
}

@MainActor
final class LegacyAudioMigrationSessionTests: XCTestCase {
    private func fixture() throws -> (LegacyAudioImportFixture, @Sendable () -> LegacyAudioMigrationCoordinator) {
        let fixture = try LegacyAudioImportFixture()
        let suite = "LegacyMigrationSession.\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        try fixture.writeSource(chapters: [0])
        let converted = fixture.root.appendingPathComponent("converted-0.mp3")
        try LegacyAudioImportFixture.audio.write(to: converted)
        let storeRoot = fixture.storeRoot, legacyRoot = fixture.legacyRoot
        return (fixture, {
            LegacyAudioMigrationCoordinator(
                store: LocalAudioArtifactStore(root: storeRoot), legacyRoot: legacyRoot,
                defaults: UserDefaults(suiteName: suite) ?? .standard,
                convertedChapters: { _ in
                    .init(bookID: "book", usesReaderAxis: true, indexBase: 0, files: [0: converted])
                },
                isPlayable: { _ in true })
        })
    }

    private let book = LegacyAudioMigrationSession.Book(id: "book", title: "Book", author: nil, jobID: "job")

    func testStartMovesTheAudioOnceAndIsNotRepeatedInTheSameLaunch() async throws {
        let (fixture, coordinator) = try fixture()
        let session = LegacyAudioMigrationSession()
        session.startIfNeeded(books: nil, coordinator: coordinator, delayNanoseconds: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source(chapter: 0).path),
                      "Nothing runs while the library has not loaded")
        session.startIfNeeded(books: [book], coordinator: coordinator, delayNanoseconds: 0)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: fixture.legacyRoot.appendingPathComponent("job").path)
        }, object: nil)
        await fulfillment(of: [moved], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 0)), LegacyAudioImportFixture.audio)

        // A second start in the same launch must not run: given time to work,
        // it would move this job too.
        try fixture.writeSource(job: "later", chapters: [0])
        session.startIfNeeded(books: [.init(id: "book", title: "Book", author: nil, jobID: "later")],
                              coordinator: coordinator, delayNanoseconds: 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try Data(contentsOf: fixture.source(job: "later", chapter: 0)), LegacyAudioImportFixture.audio)
    }

    func testAStorageRemovalStopsAMigrationThatHasNotBegunAndItStaysStopped() async throws {
        let (fixture, coordinator) = try fixture()
        let session = LegacyAudioMigrationSession()
        session.startIfNeeded(books: [book], coordinator: coordinator, delayNanoseconds: 60_000_000_000)
        await session.stop()
        session.startIfNeeded(books: [book], coordinator: coordinator, delayNanoseconds: 0)
        // Given time to work, a restarted migration would have moved the audio.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 0)), LegacyAudioImportFixture.audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
    }

    func testEveryCallerOfStopWaitsUntilTheRunningMigrationHasEnded() async throws {
        let (fixture, _) = try fixture()
        let gate = MigrationGate()
        let storeRoot = fixture.storeRoot, legacyRoot = fixture.legacyRoot
        let session = LegacyAudioMigrationSession()
        session.startIfNeeded(books: [book], coordinator: {
            LegacyAudioMigrationCoordinator(
                store: LocalAudioArtifactStore(root: storeRoot), legacyRoot: legacyRoot, defaults: .standard,
                convertedChapters: { _ in
                    // Holds the run inside its work, deaf to cancellation, until released.
                    await gate.hold()
                    return nil
                },
                isPlayable: { _ in true })
        }, delayNanoseconds: 0)
        await fulfillment(of: [gate.entered], timeout: 10)
        let finished = StopCount()
        let first = Task { await session.stop(); await finished.add() }
        let second = Task { await session.stop(); await finished.add() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let early = await finished.value
        XCTAssertEqual(early, 0, "No caller may return while the migration is still working")
        await gate.release()
        await first.value
        await second.value
        let late = await finished.value
        XCTAssertEqual(late, 2)
    }

    func testAJobSharedByTwoBooksIsAttributedToNeitherAndAnUnloadedLibraryGivesNoBooks() throws {
        let suite = "LegacyMigrationSessionLibrary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let entities = [("a", "shared"), ("b", "shared"), ("c", "own"), ("d", nil)].map { id, job in
            BookEntity(id: id, title: id.uppercased(), bookmark: Data([1]), displayFilename: "\(id).epub",
                       addedAt: .now, lastJobId: job)
        }
        defaults.set(try JSONEncoder().encode(entities), forKey: "library.books.v1")
        let books = try XCTUnwrap(LegacyAudioMigrationSession.books(in: LibraryStore(defaults: defaults)))
        XCTAssertEqual(books.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(books.map(\.jobID), [nil, nil, "own", nil])

        defaults.set(Data("not a library".utf8), forKey: "library.books.v1")
        XCTAssertNil(LegacyAudioMigrationSession.books(in: LibraryStore(defaults: defaults)),
                     "A library that failed to load must not read as an empty library")
    }

    func testTheLoggedSummaryCarriesCountsOnly() {
        var report = LegacyAudioMigrationCoordinator.Report()
        report.books = ["secret-book": .complete(imported: 2, alreadyPresent: 0), "other": .unprovenMapping]
        report.storeCopies = ["secret-book": .partial(imported: 0, alreadyPresent: 1, deferred: 1)]
        report.skippedByVersion = ["done"]
        XCTAssertEqual(LegacyAudioMigrationSession.summary(of: report),
                       "alreadyDone=1 complete=1 partial=1 unproven=1")
    }
}
