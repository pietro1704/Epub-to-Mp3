import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LegacyAudioMigrationCoordinatorTests: XCTestCase {
    private typealias Converted = LegacyAudioMigrationCoordinator.ConvertedChapters

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

    /// Writes the job's own converted chapter files, as the Rust output holds them.
    private func converted(
        _ fixture: LegacyAudioImportFixture, job: String = "job", base: Int, chapters: [Int],
        bytes: Data = LegacyAudioImportFixture.audio, fileExtension: String = "mp3"
    ) throws -> Converted {
        let directory = fixture.root.appendingPathComponent("RustConversions/\(job)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [Int: URL] = [:]
        for chapter in chapters {
            let url = directory.appendingPathComponent("converted-\(chapter).\(fileExtension)")
            try bytes.write(to: url)
            files[chapter] = url
        }
        return Converted(indexBase: base, files: files)
    }

    private func coordinator(_ fixture: LegacyAudioImportFixture, _ defaults: UserDefaults,
                             converted: [String: Converted]) -> LegacyAudioMigrationCoordinator {
        .init(store: LocalAudioArtifactStore(root: fixture.storeRoot), legacyRoot: fixture.legacyRoot,
              defaults: defaults, convertedChapters: { converted[$0] })
    }

    private func book(_ id: String = "book", job: String? = "job") -> LegacyAudioMigrationCoordinator.Book {
        .init(id: id, title: "Library title", author: "Author", jobID: job)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testProvenChaptersMoveToTheStoreAndTheirLegacyCopiesAreRemoved() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2, 3])
        let job = try converted(fixture, base: 1, chapters: [1, 2, 3])
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .complete(imported: 3, alreadyPresent: 0))
        XCTAssertTrue(report.storeCopies.isEmpty)
        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.chapters.map(\.index), [0, 1, 2], "One-based job chapters land on the zero-based axis")
        XCTAssertTrue(manifest.chapters.allSatisfy { $0.state == .available && $0.retention == .downloaded })
        for chapter in 0...2 {
            XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: chapter)), LegacyAudioImportFixture.audio)
        }
        XCTAssertFalse(exists(fixture.legacyRoot.appendingPathComponent("job")),
                       "A job folder with nothing left is removed")
        for chapter in 1...3 {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(job.files[chapter])), LegacyAudioImportFixture.audio,
                           "The converted output is only read")
        }
    }

    func testAudioThatStartsInsideItsChapterKeepsThatOffsetInTheStore() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [8, 9])
        var job = try converted(fixture, base: 0, chapters: [8, 9])
        job.textOffsets = [8: 120]
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .complete(imported: 2, alreadyPresent: 0))
        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.chapters.map(\.index), [8, 9])
        XCTAssertEqual(manifest.chapters.map(\.textOffset), [120, nil])
        let snapshot = try await LocalAudioArtifactStore(root: fixture.storeRoot)
            .playableSnapshot(bookID: "book", engine: "piper", voice: "auto", language: nil)
        XCTAssertEqual(snapshot?.playableChapters.map(\.textOffset), [120, nil])
    }

    func testMigratedDownloadsStayVisibleUnderTheBookTitleInTheSameDocumentsFolder() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 1])
        let job = try converted(fixture, base: 0, chapters: [0, 1])
        // On the iPhone the legacy job folders and the visible copies share Documents/Audiobooks.
        let store = LocalAudioArtifactStore(
            root: fixture.storeRoot, visibleCopies: DownloadedAudioFilesMirror(root: fixture.legacyRoot))
        let migration = LegacyAudioMigrationCoordinator(
            store: store, legacyRoot: fixture.legacyRoot, defaults: defaults, convertedChapters: { _ in job })
        let report = try await migration.run(books: [book()])
        XCTAssertEqual(report.books["book"], .complete(imported: 2, alreadyPresent: 0))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.legacyRoot.path), ["Library title"],
                       "The unreadable job folder gives way to a folder named after the book")
        let visible = try FileManager.default.contentsOfDirectory(
            atPath: fixture.legacyRoot.appendingPathComponent("Library title").path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(visible, ["01 - Chapter 0.mp3", "02 - Chapter 1.mp3"])
        XCTAssertEqual(try Data(contentsOf: fixture.legacyRoot.appendingPathComponent("Library title/01 - Chapter 0.mp3")),
                       LegacyAudioImportFixture.audio)
    }

    func testASecondRunDoesNothing() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 1])
        let job = try converted(fixture, base: 0, chapters: [0, 1])
        let migration = coordinator(fixture, defaults, converted: ["job": job])
        let first = try await migration.run(books: [book()])
        XCTAssertEqual(first.books["book"], .complete(imported: 2, alreadyPresent: 0))
        let manifestBytes = try Data(contentsOf: fixture.destinationManifest())
        let second = try await migration.run(books: [book()])
        XCTAssertEqual(second.skippedByVersion, ["book"])
        XCTAssertTrue(second.books.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest()), manifestBytes)
        // Without the completion record the job simply has no legacy audio left.
        let fresh = try XCTUnwrap(UserDefaults(suiteName: "LegacyMigration.fresh.\(UUID().uuidString)"))
        let third = try await coordinator(fixture, fresh, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(third.books["book"], .noLegacyAudio)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest()), manifestBytes)
    }

    func testUnprovenIndexBaseAndMissingLegacyAudioTouchNothing() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let legacyManifest = try Data(contentsOf: fixture.sourceManifest())
        let migration = coordinator(fixture, defaults, converted: [:])
        let report = try await migration.run(books: [book(), book("other", job: "no-such-job"), book("none", job: nil)])
        XCTAssertEqual(report.books["book"], .unprovenMapping)
        XCTAssertEqual(report.books["other"], .noLegacyAudio)
        XCTAssertEqual(report.books["none"], .noLegacyAudio)
        XCTAssertFalse(exists(fixture.storeRoot))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceManifest()), legacyManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 2)), LegacyAudioImportFixture.audio)
        // An unproven job is examined again once its conversion can be read.
        let job = try converted(fixture, base: 1, chapters: [1, 2])
        let later = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(later.books["book"], .complete(imported: 2, alreadyPresent: 0))
    }

    func testDamagedAudioStaysInTheLegacyLayoutUntilARetrySucceeds() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let damaged = Data("damaged".utf8)
        try damaged.write(to: fixture.source(chapter: 2))
        var manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: fixture.sourceManifest()))
        manifest.chapters[1] = .init(index: 2, title: "Chapter 2", mp3FileName: "chapter-2.mp3", mp3Bytes: 7,
                                     downloadedAt: manifest.chapters[1].downloadedAt)
        try JSONEncoder().encode(manifest).write(to: fixture.sourceManifest())
        let job = try converted(fixture, base: 1, chapters: [1, 2])
        let migration = coordinator(fixture, defaults, converted: ["job": job])
        let first = try await migration.run(books: [book()])
        XCTAssertEqual(first.books["book"], .partial(imported: 1, alreadyPresent: 0, deferred: 1))
        XCTAssertFalse(exists(fixture.source(chapter: 1)), "The verified chapter leaves the legacy layout")
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 2)), damaged, "The failed chapter is untouched")
        let remaining = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: fixture.sourceManifest()))
        XCTAssertEqual(remaining.chapters.map(\.index), [2])
        XCTAssertEqual(remaining.totalBytes, 7)
        XCTAssertEqual(try LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book")?.chapters.map(\.index), [0])

        try fixture.writeSource(chapters: [2])
        let retry = try await migration.run(books: [book()])
        XCTAssertEqual(retry.books["book"], .complete(imported: 1, alreadyPresent: 0))
        XCTAssertEqual(try LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book")?.chapters.map(\.index), [0, 1])
    }

    func testUnreadableLegacyManifestIsReportedWithoutTouchingAnything() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource()
        try Data("not json".utf8).write(to: fixture.sourceManifest())
        let job = try converted(fixture, base: 1, chapters: [1])
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .unreadable)
        XCTAssertFalse(exists(fixture.storeRoot))
        XCTAssertEqual(try Data(contentsOf: fixture.source()), LegacyAudioImportFixture.audio)
    }

    func testChapterTheConversionDoesNotContainStaysWhereItIsWithTheReaderText() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 5])
        let readerText = fixture.legacyRoot.appendingPathComponent("job/fulltext.json")
        try Data("{}".utf8).write(to: readerText)
        try Data("2026-01-01T00:00:00Z".utf8).write(to: fixture.legacyRoot.appendingPathComponent("job/last_access"))
        let job = try converted(fixture, base: 0, chapters: [0])
        let migration = coordinator(fixture, defaults, converted: ["job": job])
        let report = try await migration.run(books: [book()])
        XCTAssertEqual(report.books["book"], .partial(imported: 1, alreadyPresent: 0, deferred: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 5)), LegacyAudioImportFixture.audio)
        let remaining = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: fixture.sourceManifest()))
        XCTAssertEqual(remaining.chapters.map(\.index), [5])
        XCTAssertEqual(try LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book")?.chapters.map(\.index), [0])

        // Once the conversion contains it, the rest moves and only the reader text remains.
        let full = try converted(fixture, base: 0, chapters: [0, 5])
        let later = try await coordinator(fixture, defaults, converted: ["job": full]).run(books: [book()])
        XCTAssertEqual(later.books["book"], .complete(imported: 1, alreadyPresent: 0))
        XCTAssertEqual(try Data(contentsOf: readerText), Data("{}".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.legacyRoot.appendingPathComponent("job").path), ["fulltext.json"])
    }

    func testLegacyCopyIsKeptWhileTheConvertedFileIsNotProvenPlayable() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 1])
        // Chapter 0: the converted file is different, undecodable bytes. Chapter 1:
        // different bytes that decode to their end (a repaired or re-encoded file).
        var job = try converted(fixture, base: 0, chapters: [0], bytes: Data("truncated".utf8))
        let playable = try converted(fixture, base: 0, chapters: [1],
                                     bytes: LegacyAudioImportFixture.wave(), fileExtension: "wav")
        job = Converted(indexBase: 0, files: job.files.merging(playable.files) { $1 })
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .partial(imported: 2, alreadyPresent: 0, deferred: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 0)), LegacyAudioImportFixture.audio,
                       "The only proven copy of chapter 0 outside the store must stay playable")
        XCTAssertFalse(exists(fixture.source(chapter: 1)))
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 0)), LegacyAudioImportFixture.audio)
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 1)), LegacyAudioImportFixture.audio)
    }

    func testDifferentAudioAlreadyInTheStoreIsNeverReplacedAndTheLegacyCopyStays() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0])
        let newer = Data(repeating: 9, count: 64)
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Newer", retention: .downloaded, audio: newer)
        ])
        let job = try converted(fixture, base: 0, chapters: [0])
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .partial(imported: 0, alreadyPresent: 0, deferred: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 0)), newer)
        XCTAssertEqual(try Data(contentsOf: fixture.source(chapter: 0)), LegacyAudioImportFixture.audio)
    }

    func testCopyOfTheStoresOwnAudioProtectsThatAudioBeforeItIsRemoved() async throws {
        let (fixture, defaults) = try fixture()
        // The listener pressed Download on audio that played from the store: the
        // previous layout copied it under the store's own job id.
        try fixture.writeSource(job: "embedded-book", chapters: [0, 3])
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Zero", retention: .temporary, audio: LegacyAudioImportFixture.audio)
        ])
        let report = try await coordinator(fixture, defaults, converted: [:]).run(books: [book(job: nil)])
        XCTAssertEqual(report.books["book"], .noLegacyAudio)
        XCTAssertEqual(report.storeCopies["book"], .complete(imported: 1, alreadyPresent: 1))
        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.chapters.map(\.index), [0, 3])
        XCTAssertEqual(manifest.chapters.map(\.retention), [.downloaded, .downloaded],
                       "A cache clear must not remove audio the listener downloaded")
        XCTAssertFalse(exists(fixture.legacyRoot.appendingPathComponent("embedded-book")))
        let cleared = LocalAudioArtifactStore(root: fixture.storeRoot)
        try await cleared.clearTemporaryAudio()
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 0)), LegacyAudioImportFixture.audio)
    }

    func testEntryLeftWithoutItsFileByAnInterruptedRunIsDropped() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0, 1])
        let job = try converted(fixture, base: 0, chapters: [0, 1])
        // State after an interruption: chapter 0 is in the store and its legacy
        // file is gone, but the legacy manifest still lists it.
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Chapter 0", retention: .downloaded, audio: LegacyAudioImportFixture.audio)
        ])
        try FileManager.default.removeItem(at: fixture.source(chapter: 0))
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .complete(imported: 1, alreadyPresent: 0))
        XCTAssertFalse(exists(fixture.legacyRoot.appendingPathComponent("job")))
        XCTAssertEqual(try LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book")?.chapters.map(\.index), [0, 1])
    }

    func testEntryWithoutAFileIsKeptWhenTheStoreDoesNotHoldThatAudio() async throws {
        let (fixture, defaults) = try fixture()
        try fixture.writeSource(chapters: [0])
        try FileManager.default.removeItem(at: fixture.source(chapter: 0))
        let before = try Data(contentsOf: fixture.sourceManifest())
        let job = try converted(fixture, base: 0, chapters: [0])
        let report = try await coordinator(fixture, defaults, converted: ["job": job]).run(books: [book()])
        XCTAssertEqual(report.books["book"], .partial(imported: 0, alreadyPresent: 0, deferred: 1))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceManifest()), before)
    }
}
