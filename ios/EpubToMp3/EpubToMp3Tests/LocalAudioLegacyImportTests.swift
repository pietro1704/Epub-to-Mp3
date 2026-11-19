import AVFoundation
import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LocalAudioLegacyImportTests: XCTestCase {
    private func fixture() throws -> LegacyAudioImportFixture {
        let fixture = try LegacyAudioImportFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    func testImportsPlayableAudioWithCanonicalIdentityAndRetainsLegacyBytes() async throws {
        let fixture = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let legacyManifest = try Data(contentsOf: fixture.sourceManifest())
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(
            from: fixture.legacyRoot, identity: fixture.identity(mapping: [1: 0, 2: 4]))
        XCTAssertEqual(report.chapters, [1: .imported, 2: .imported])
        let reopened = LocalAudioArtifactStore(root: fixture.storeRoot)
        let saved = try await reopened.manifest(bookID: "book")
        let manifest = try XCTUnwrap(saved)
        XCTAssertEqual(manifest.bookID, "book")
        XCTAssertEqual(manifest.bookTitle, "Library title")
        XCTAssertEqual(manifest.author, "Author")
        XCTAssertEqual(manifest.chapters.map(\.index), [0, 4])
        XCTAssertTrue(manifest.chapters.allSatisfy { $0.state == .available && $0.retention == .downloaded })
        XCTAssertEqual(try Data(contentsOf: fixture.destination()), LegacyAudioImportFixture.audio)
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 4)), LegacyAudioImportFixture.audio)
        XCTAssertEqual(try Data(contentsOf: fixture.source()), LegacyAudioImportFixture.audio)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceManifest()), legacyManifest)
        let snapshot = try await reopened.playableSnapshot(bookID: "book", engine: "piper", voice: "auto", language: nil)
        XCTAssertEqual(snapshot?.playableChapters.map(\.index), [0, 4])
        XCTAssertEqual(snapshot?.chapterIndexBase, 0)
        try assertNoStaging(fixture)
    }

    func testRetryIsIdempotentAndPartialImportsMergeWithoutReplacingExistingMetadata() async throws {
        let fixture = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let first = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(first.chapters, [1: .imported, 2: .unmapped])
        let manifestBeforeRetry = try Data(contentsOf: fixture.destinationManifest())
        let retry = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(retry.chapters, [1: .alreadyPresent, 2: .unmapped])
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest()), manifestBeforeRetry)
        let firstArtifact = try await store.artifact(bookID: "book", chapterIndex: 0)
        let second = try await store.importLegacyAudio(
            from: fixture.legacyRoot, identity: fixture.identity(mapping: [1: 0, 2: 7]))
        XCTAssertEqual(second.chapters, [1: .alreadyPresent, 2: .imported])
        let preservedArtifact = try await store.artifact(bookID: "book", chapterIndex: 0)
        XCTAssertEqual(preservedArtifact, firstArtifact)
        let manifest = try await store.manifest(bookID: "book")
        XCTAssertEqual(manifest?.chapters.map(\.index), [0, 7])
    }

    func testConflictingAudioIsPreservedWhileUnrelatedChapterImports() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        let firstArtifact = try await store.artifact(bookID: "book", chapterIndex: 0)
        // A distinct, still playable file from a later job must not replace chapter zero.
        let differentAudio = LegacyAudioImportFixture.audio + LegacyAudioImportFixture.audio
        try fixture.writeSource(job: "second-job", chapters: [5, 6], bytes: differentAudio)
        let report = try await store.importLegacyAudio(
            from: fixture.legacyRoot, identity: fixture.identity(job: "second-job", mapping: [5: 0, 6: 3]))
        XCTAssertEqual(report.chapters, [5: .conflict, 6: .imported])
        XCTAssertEqual(try Data(contentsOf: fixture.destination()), LegacyAudioImportFixture.audio)
        let preserved = try await store.artifact(bookID: "book", chapterIndex: 0)
        XCTAssertEqual(preserved, firstArtifact)
        XCTAssertEqual(try Data(contentsOf: fixture.destination(chapter: 3)), differentAudio)
        XCTAssertEqual(try Data(contentsOf: fixture.source(job: "second-job", chapter: 5)), differentAudio)
    }

    func testNonEmptyInvalidAudioDoesNotProduceAnAvailableArtifact() async throws {
        let fixture = try fixture()
        let bytes = Data("not an audio stream".utf8)
        try fixture.writeSource(bytes: bytes)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(report.chapters, [1: .invalidAudio])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationManifest().path))
        XCTAssertEqual(try Data(contentsOf: fixture.source()), bytes)
        try assertNoStaging(fixture)
    }

    func testChangedSourceSizeIsDeferredWithoutPublishing() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        try (LegacyAudioImportFixture.audio + Data([0])).write(to: fixture.source())
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(report.chapters, [1: .invalidSource])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
        try assertNoStaging(fixture)
    }

    func testEstimatedLengthTolerancePassesEarlyCleanEndAndRejectsRealTruncation() {
        let accept = LocalAudioImportFiles.isAcceptableDecodeEnd
        XCTAssertTrue(accept(1_000_000, 1_000_000))
        // VBR without Xing/Info: the estimate overshoots by a few percent.
        XCTAssertTrue(accept(970_000, 1_000_000))
        XCTAssertTrue(accept(950_000, 1_000_000))
        XCTAssertFalse(accept(949_999, 1_000_000))
        // The fixture truncated to half its declared length, and empty decodes.
        XCTAssertFalse(accept(8_192, 16_384))
        XCTAssertFalse(accept(0, 16_384))
        XCTAssertFalse(accept(10, 0))
    }

    func testTruncatedContainerIsNotPublished() async throws {
        let fixture = try fixture()
        let truncated = LegacyAudioImportFixture.wave(storedFrames: 8_192)
        // The manifest describes the actual truncated byte count, so import must
        // reject the audio itself rather than relying on its byte-count guard.
        try fixture.writeSource(bytes: truncated)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let rejected = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(rejected.chapters, [1: .invalidAudio])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationManifest().path))
        XCTAssertEqual(try Data(contentsOf: fixture.source()), truncated)
        try assertNoStaging(fixture)

        // Replacing the damaged source with real MP3 audio permits retry.
        try fixture.writeSource()
        let accepted = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(accepted.chapters, [1: .imported])
    }

    func testWrongJobAndAmbiguousCanonicalMappingAreRejectedBeforeWrites() async throws {
        let fixture = try fixture()
        try fixture.writeSource(chapters: [1, 2])
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        do {
            _ = try await store.importLegacyAudio(
                from: fixture.legacyRoot, identity: fixture.identity(mapping: [1: 0, 2: 0]))
            XCTFail("Two legacy chapters cannot claim the same canonical chapter")
        } catch LocalAudioImportFiles.Failure.invalidIdentity { }
        var manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: fixture.sourceManifest()))
        manifest.jobId = "different-job"
        try JSONEncoder().encode(manifest).write(to: fixture.sourceManifest())
        do {
            _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
            XCTFail("The requested job must match its persisted manifest")
        } catch LocalAudioImportFiles.Failure.invalidIdentity { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
    }

    func testUnknownChapterMappingLeavesSourceAndDestinationUntouched() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let manifest = try Data(contentsOf: fixture.sourceManifest())
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity(mapping: [:]))
        XCTAssertEqual(report.chapters, [1: .unmapped])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceManifest()), manifest)
        XCTAssertEqual(try Data(contentsOf: fixture.source()), LegacyAudioImportFixture.audio)
    }

    func testSourceSymlinkCannotImportAnOutsideFile() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let outside = fixture.root.appendingPathComponent("outside.mp3")
        try FileManager.default.moveItem(at: fixture.source(), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.source(), withDestinationURL: outside)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(report.chapters, [1: .invalidSource])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
        XCTAssertEqual(try Data(contentsOf: outside), LegacyAudioImportFixture.audio)
    }

    func testDestinationSymlinkAndCorruptManifestAreNotRepairedOrOverwritten() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        let book = fixture.storeRoot.appendingPathComponent("book")
        try FileManager.default.createSymbolicLink(at: book, withDestinationURL: outside)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        do {
            _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
            XCTFail("Destination aliases cannot receive imported audio")
        } catch LocalAudioImportFiles.Failure.unsafePath { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        try FileManager.default.removeItem(at: book)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let corrupt = Data("undecodable current manifest".utf8)
        try corrupt.write(to: fixture.destinationManifest())
        do {
            _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
            XCTFail("An unreadable current manifest must be preserved")
        } catch is DecodingError { }
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest()), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
    }

    func testExistingDestinationBookIdentityCannotBeClaimedByAnotherBook() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        let bytes = try Data(contentsOf: fixture.destinationManifest())
        let otherBook = fixture.storeRoot.appendingPathComponent("other-book")
        try FileManager.default.moveItem(at: fixture.storeRoot.appendingPathComponent("book"), to: otherBook)
        do {
            _ = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity(book: "other-book"))
            XCTFail("Destination manifest book identity must match the explicit import identity")
        } catch LocalAudioImportFiles.Failure.destinationConflict { }
        XCTAssertEqual(try Data(contentsOf: fixture.destinationManifest(book: "other-book")), bytes)
    }

    func testIdenticalOrphanFromInterruptedPublicationIsRecoveredWithoutReplacingAudio() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let destination = fixture.destination()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Model the on-disk boundary: audio was renamed, manifest was not saved.
        try FileManager.default.copyItem(at: fixture.source(), to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let report = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(report.chapters, [1: .imported])
        let after = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try Data(contentsOf: destination), LegacyAudioImportFixture.audio)
        let saved = try await store.artifact(bookID: "book", chapterIndex: 0)
        XCTAssertEqual(saved?.state, .available)
    }

    func testDestinationWriteFailureLeavesLegacyAvailableForRetry() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let book = fixture.storeRoot.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let obstruction = book.appendingPathComponent("chapters")
        let sentinel = Data("not a directory".utf8)
        try sentinel.write(to: obstruction)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let failed = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        guard case .failed? = failed.chapters[1] else { return XCTFail("Write failure must be reported") }
        XCTAssertEqual(try Data(contentsOf: obstruction), sentinel)
        XCTAssertEqual(try Data(contentsOf: fixture.source()), LegacyAudioImportFixture.audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationManifest().path))
        try FileManager.default.removeItem(at: obstruction)
        let retried = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(retried.chapters, [1: .imported])
    }

    func testCancelledAdmissionDoesNotPublishOrRemoveAudioAndCanRetry() async throws {
        let fixture = try fixture()
        try fixture.writeSource()
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        }
        do {
            _ = try await operation.value
            XCTFail("Cancellation must stop admission")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
        XCTAssertEqual(try Data(contentsOf: fixture.source()), LegacyAudioImportFixture.audio)
        let retry = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(retry.chapters, [1: .imported])
    }

    func testCancellationDuringDecodePreservesCancellationAndRemovesOnlyStaging() async throws {
        let fixture = try fixture()
        let bytes = LegacyAudioImportFixture.audio
        try fixture.writeSource(bytes: bytes)
        let store = LocalAudioArtifactStore(root: fixture.storeRoot)
        let operation = Task {
            try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity()) { progress in
                if case .decoded(legacyChapterIndex: 1, frames: 4096) = progress {
                    // Cancel only after a real buffer was decoded, never before
                    // admission or through a substituted validator/file service.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await operation.value
            XCTFail("Cancellation after decoded progress must propagate, not become invalidAudio")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationManifest().path))
        XCTAssertEqual(try Data(contentsOf: fixture.source()), bytes)
        try assertNoStaging(fixture)
        let retry = try await store.importLegacyAudio(from: fixture.legacyRoot, identity: fixture.identity())
        XCTAssertEqual(retry.chapters, [1: .imported])
    }

    private func assertNoStaging(_ fixture: LegacyAudioImportFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let files = FileManager.default.enumerator(atPath: fixture.root.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(files.contains { $0.contains(".import-") }, file: file, line: line)
    }
}
