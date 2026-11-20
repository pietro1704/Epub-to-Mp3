import Foundation
import XCTest
@testable import EpubToMp3

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
                convertedChapters: { _ in .init(indexBase: 0, files: [0: converted]) })
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

        try fixture.writeSource(job: "later", chapters: [0])
        session.startIfNeeded(books: [.init(id: "other", title: "Other", author: nil, jobID: "later")],
                              coordinator: coordinator, delayNanoseconds: 0)
        await session.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source(job: "later", chapter: 0).path))
    }

    func testAStorageRemovalStopsAMigrationThatHasNotBegunAndItStaysStopped() async throws {
        let (fixture, coordinator) = try fixture()
        let session = LegacyAudioMigrationSession()
        session.startIfNeeded(books: [book], coordinator: coordinator, delayNanoseconds: 60_000_000_000)
        await session.stop()
        session.startIfNeeded(books: [book], coordinator: coordinator, delayNanoseconds: 0)
        await session.stop()
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 0)), LegacyAudioImportFixture.audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
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
