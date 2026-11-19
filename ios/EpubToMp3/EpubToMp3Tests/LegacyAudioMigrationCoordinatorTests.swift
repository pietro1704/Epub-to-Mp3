import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LegacyAudioMigrationCoordinatorTests: XCTestCase {
    private func fixture() throws -> (LegacyAudioImportFixture, UserDefaults) {
        let fixture = try LegacyAudioImportFixture()
        let suite = "LegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.root)
            defaults.removePersistentDomain(forName: suite)
        }
        return (fixture, defaults)
    }

    private func coordinator(_ fixture: LegacyAudioImportFixture, _ defaults: UserDefaults,
                             bases: [String: Int]) -> LegacyAudioMigrationCoordinator {
        .init(store: LocalAudioArtifactStore(root: fixture.storeRoot), legacyRoot: fixture.legacyRoot,
              defaults: defaults, provenIndexBase: { bases[$0] })
    }

    private func book(_ id: String = "book", job: String? = "job") -> LegacyAudioMigrationCoordinator.Book {
        .init(id: id, title: "Library title", author: "Author", jobID: job)
    }

    func testOneBasedLegacyIndicesMapToZeroBasedChaptersAndKeepEveryLegacyFile() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2, 3])
        let before = try Data(contentsOf: fixture.sourceManifest())
        let report = try await coordinator(fixture, defaults, bases: ["job": 1]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .complete(imported: 3, alreadyPresent: 0))
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let manifest = try await store.manifest(bookID: "book")
        XCTAssertEqual(manifest?.chapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(try Data(contentsOf: fixture.sourceManifest()), before)
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 3)), LegacyAudioImportFixture.audio,
                       "Legacy audio is never removed by the coordinator")
    }

    func testZeroBasedJobsKeepTheirIndicesAndASecondRunDoesNothing() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 1])
        let migration = coordinator(fixture, defaults, bases: ["job": 0])
        let first = try await migration.run(books: [book()])
        XCTAssertEqual(first.books["book"], .complete(imported: 2, alreadyPresent: 0))
        let manifestBytes = try Data(contentsOf: fixture.destinationManifest())
        let second = try await migration.run(books: [book()])
        XCTAssertEqual(second.skippedByVersion, ["book"])
        XCTAssertTrue(second.books.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest()), manifestBytes)
    }

    func testUnprovenIndexBaseAndMissingLegacyAudioWriteNothing() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let migration = coordinator(fixture, defaults, bases: [:])
        let report = try await migration.run(books: [book(), book("other", job: "no-such-job"), book("none", job: nil)])
        XCTAssertEqual(report.books["book"], .unprovenMapping)
        XCTAssertEqual(report.books["other"], .noLegacyAudio)
        XCTAssertEqual(report.books["none"], .noLegacyAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
        // An unproven job is examined again once its base becomes known.
        let later = try await coordinator(fixture, defaults, bases: ["job": 1]).run(books: [book()])
        XCTAssertEqual(later.books["book"], .complete(imported: 2, alreadyPresent: 0))
    }

    func testPartialImportIsNotRecordedAsDoneAndCompletesOnRetry() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        // The second chapter's audio is damaged, so it stays in the legacy layout.
        try Data("damaged".utf8).write(to: fixture.source(chapter: 2))
        var manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: fixture.sourceManifest()))
        manifest.chapters[1] = .init(index: 2, title: "Chapter 2", mp3FileName: "chapter-2.mp3", mp3Bytes: 7,
                                     downloadedAt: manifest.chapters[1].downloadedAt)
        try JSONEncoder().encode(manifest).write(to: fixture.sourceManifest())
        let migration = coordinator(fixture, defaults, bases: ["job": 1])
        let first = try await migration.run(books: [book()])
        XCTAssertEqual(first.books["book"], .partial(imported: 1, alreadyPresent: 0, deferred: 1))
        try fixture.writeSource(chapters: [1, 2])
        let retry = try await migration.run(books: [book()])
        XCTAssertEqual(retry.books["book"], .complete(imported: 1, alreadyPresent: 1))
    }

    func testUnreadableLegacyManifestIsReportedWithoutTouchingTheStore() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource()
        try Data("not json".utf8).write(to: fixture.sourceManifest())
        let report = try await coordinator(fixture, defaults, bases: ["job": 1]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
    }
}
