import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LocalAudioDownloadRetentionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let storeRoot: URL
        let store: LocalAudioArtifactStore

        func source(_ name: String, _ bytes: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        func request(_ chapter: Int, title: String = "Chapter", textOffset: Int = 0)
            -> LocalAudioArtifactStore.DownloadRequest {
            .init(bookID: "book", bookTitle: "Book", author: "Author", chapterIndex: chapter,
                  chapterTitle: title, textOffset: textOffset)
        }

        func canonical(_ chapter: Int) -> URL {
            storeRoot.appendingPathComponent("book/chapters/chapter-\(chapter).mp3")
        }

        func chapterFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(
                atPath: storeRoot.appendingPathComponent("book/chapters").path).sorted()
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        return Fixture(root: root, storeRoot: storeRoot, store: LocalAudioArtifactStore(root: storeRoot))
    }

    func testDownloadKeepsACopyUnderTheBookAndASecondRequestChangesNothing() async throws {
        let fixture = try fixture()
        let bytes = Data(repeating: 7, count: 64)
        let source = try fixture.source("converted.mp3", bytes)
        let kept = try await fixture.store.retainDownload(from: source, request: fixture.request(3, title: "Three"))
        XCTAssertEqual(kept, 64)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "The converted source is only read")
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(3)), bytes)
        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.bookTitle, "Book")
        XCTAssertEqual(manifest.author, "Author")
        XCTAssertEqual(manifest.chapters.map(\.index), [3])
        XCTAssertEqual(manifest.chapters[0].title, "Three")
        XCTAssertEqual(manifest.chapters[0].state, .available)
        XCTAssertEqual(manifest.chapters[0].retention, .downloaded)
        XCTAssertEqual(manifest.chapters[0].byteCount, 64)

        _ = try await fixture.store.retainDownload(from: source, request: fixture.request(3, title: "Three"))
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(3)), bytes)
        XCTAssertEqual(try fixture.chapterFiles(), ["chapter-3.mp3"], "No staging file may remain")
        let indices = try await fixture.store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(indices, [3])
        // A relaunched store reads the same state from disk.
        let reopened = try await LocalAudioArtifactStore(root: fixture.storeRoot)
            .playableSnapshot(bookID: "book", engine: "piper", voice: "auto", language: nil)
        XCTAssertEqual(reopened?.playableChapters.map(\.index), [3])
    }

    func testDownloadReplacesOnlyItsChapterAndKeepsEverythingElseInTheManifest() async throws {
        let fixture = try fixture()
        let older = Data(repeating: 1, count: 10)
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", bookTitle: "Kept title", chapters: [
            .init(index: 0, title: "Zero", retention: .downloaded, audio: older),
            .init(index: 1, title: "One", retention: .temporary, audio: older, playbackRetentionRequested: true),
            .init(index: 2, title: "Pending")
        ])
        let newer = Data(repeating: 2, count: 20)
        _ = try await fixture.store.retainDownload(
            from: fixture.source("new.mp3", newer), request: fixture.request(1, title: "One again"))
        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.bookTitle, "Kept title", "An existing book record keeps its own title")
        XCTAssertEqual(manifest.chapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(manifest.chapters[0].retention, .downloaded)
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(0)), older)
        XCTAssertEqual(manifest.chapters[1].title, "One again")
        XCTAssertEqual(manifest.chapters[1].retention, .downloaded)
        XCTAssertEqual(manifest.chapters[1].byteCount, 20)
        XCTAssertEqual(manifest.chapters[1].playbackRetentionRequested, true)
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(1)), newer)
        XCTAssertEqual(manifest.chapters[2].state, .pending)
        XCTAssertEqual(try fixture.chapterFiles(), ["chapter-0.mp3", "chapter-1.mp3"])
    }

    func testAudioAlreadyPlayingFromTheStoreIsProtectedInPlace() async throws {
        let fixture = try fixture()
        let audio = Data(repeating: 5, count: 33)
        let urls = try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 4, title: "Four", retention: .temporary, audio: audio)
        ])
        let canonical = try XCTUnwrap(urls[4])
        let kept = try await fixture.store.retainDownload(from: canonical, request: fixture.request(4, title: "Four"))
        XCTAssertEqual(kept, 33)
        XCTAssertEqual(try Data(contentsOf: canonical), audio)
        let artifact = try LocalAudioArtifactFixture.artifact(root: fixture.storeRoot, bookID: "book", chapterIndex: 4)
        XCTAssertEqual(artifact?.retention, .downloaded)
        XCTAssertEqual(try fixture.chapterFiles(), ["chapter-4.mp3"])
    }

    func testAudioThatStartsInsideAChapterNeverReplacesKeptAudioThatCoversMoreOfIt() async throws {
        let fixture = try fixture()
        let whole = Data(repeating: 1, count: 50)
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Whole", retention: .temporary, audio: whole)
        ])
        let suffix = try fixture.source("suffix.mp3", Data(repeating: 2, count: 20))
        // The whole chapter stays and becomes the protected download.
        let kept = try await fixture.store.retainDownload(
            from: suffix, request: fixture.request(0, title: "Suffix", textOffset: 120))
        XCTAssertEqual(kept, 50)
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(0)), whole)
        var artifact = try XCTUnwrap(LocalAudioArtifactFixture.artifact(root: fixture.storeRoot, bookID: "book", chapterIndex: 0))
        XCTAssertEqual(artifact.title, "Whole")
        XCTAssertNil(artifact.textOffset)
        XCTAssertEqual(artifact.retention, .downloaded)

        // A chapter with no kept audio keeps the partial audio, marked as partial.
        _ = try await fixture.store.retainDownload(
            from: suffix, request: fixture.request(1, title: "Suffix", textOffset: 120))
        artifact = try XCTUnwrap(LocalAudioArtifactFixture.artifact(root: fixture.storeRoot, bookID: "book", chapterIndex: 1))
        XCTAssertEqual(artifact.textOffset, 120)
        let snapshot = try await fixture.store.playableSnapshot(bookID: "book", engine: "piper", voice: "auto", language: nil)
        XCTAssertEqual(snapshot?.playableChapters.map(\.textOffset), [nil, 120],
                       "Partial audio must never be presented as a whole chapter")

        // Audio that covers more of the chapter replaces the partial audio.
        let fuller = try fixture.source("fuller.mp3", Data(repeating: 3, count: 40))
        _ = try await fixture.store.retainDownload(from: fuller, request: fixture.request(1, title: "Whole one"))
        artifact = try XCTUnwrap(LocalAudioArtifactFixture.artifact(root: fixture.storeRoot, bookID: "book", chapterIndex: 1))
        XCTAssertNil(artifact.textOffset)
        XCTAssertEqual(artifact.title, "Whole one")
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(1)), Data(repeating: 3, count: 40))
    }

    func testDownloadsAreShownInTheListenersFilesAndLeaveWithTheDownload() async throws {
        let fixture = try fixture()
        let visibleRoot = fixture.root.appendingPathComponent("Documents/Audiobooks", isDirectory: true)
        let store = LocalAudioArtifactStore(
            root: fixture.storeRoot, visibleCopies: DownloadedAudioFilesMirror(root: visibleRoot))
        func visible(_ folder: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: visibleRoot.appendingPathComponent(folder).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        let converted = try fixture.source("converted.mp3", Data(repeating: 4, count: 24))
        _ = try await store.retainDownload(from: converted, request: fixture.request(0, title: "Opening"))
        _ = try await store.retainDownload(from: converted, request: fixture.request(1, title: "Second"))
        XCTAssertEqual(visible("Book"), ["01 - Opening.mp3", "02 - Second.mp3"])
        XCTAssertEqual(try Data(contentsOf: visibleRoot.appendingPathComponent("Book/02 - Second.mp3")),
                       Data(repeating: 4, count: 24))

        // Listened audio that becomes protected is shown too; temporary audio is not.
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 2, title: "Heard", retention: .temporary, audio: Data(repeating: 5, count: 8))
        ])
        XCTAssertEqual(visible("Book"), ["01 - Opening.mp3", "02 - Second.mp3"])
        try await store.promote(bookID: "book", chapterIndex: 2)
        XCTAssertEqual(visible("Book"), ["01 - Opening.mp3", "02 - Second.mp3", "03 - Heard.mp3"])

        // Deleting the visible copy does not end the Download, and a repeated
        // promotion does not bring the copy back.
        try FileManager.default.removeItem(at: visibleRoot.appendingPathComponent("Book/03 - Heard.mp3"))
        try await store.promote(bookID: "book", chapterIndex: 2)
        XCTAssertEqual(visible("Book"), ["01 - Opening.mp3", "02 - Second.mp3"])
        let kept = try await store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(kept, [0, 1, 2])

        try await store.releaseDownload(bookID: "book", chapterIndex: 0, playbackSource: converted)
        XCTAssertEqual(visible("Book"), ["02 - Second.mp3"])
        try await store.removeAllAudio(bookID: "book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: visibleRoot.appendingPathComponent("Book").path))
    }

    func testEmptyOrMissingSourceLeavesTheKeptChapterUntouched() async throws {
        let fixture = try fixture()
        let audio = Data(repeating: 9, count: 12)
        try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Zero", retention: .downloaded, audio: audio)
        ])
        let before = try Data(contentsOf: fixture.storeRoot.appendingPathComponent("book/manifest.json"))
        for source in [try fixture.source("empty.mp3", Data()), fixture.root.appendingPathComponent("missing.mp3")] {
            do {
                _ = try await fixture.store.retainDownload(from: source, request: fixture.request(0))
                XCTFail("A source without audio must not be kept")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(0)), audio)
        XCTAssertEqual(try Data(contentsOf: fixture.storeRoot.appendingPathComponent("book/manifest.json")), before)
        XCTAssertEqual(try fixture.chapterFiles(), ["chapter-0.mp3"])
    }

    func testManifestOfAnotherBookOrLayoutIsNeverExtended() async throws {
        let fixture = try fixture()
        let directory = fixture.storeRoot.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = LocalAudioArtifactStore.Manifest(
            schemaVersion: LocalAudioArtifactStore.schemaVersion, bookID: "another-book",
            bookTitle: "Other", author: nil, chapters: [], updatedAt: Date())
        let bytes = try JSONEncoder().encode(foreign)
        try bytes.write(to: directory.appendingPathComponent("manifest.json"))
        let source = try fixture.source("converted.mp3", Data(repeating: 3, count: 8))
        do {
            _ = try await fixture.store.retainDownload(from: source, request: fixture.request(0))
            XCTFail("A manifest that names another book must stop the Download")
        } catch LocalAudioImportFiles.Failure.destinationConflict {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.canonical(0).path))
        do {
            _ = try await fixture.store.retainDownload(
                from: source,
                request: .init(bookID: "../escape", bookTitle: "x", author: nil, chapterIndex: 0, chapterTitle: "x"))
            XCTFail("A book id that is not one path component must be refused")
        } catch LocalAudioImportFiles.Failure.invalidIdentity {}
    }

    func testEndingADownloadRemovesAKeptCopyButKeepsAudioThatIsPlayingFromTheStore() async throws {
        let fixture = try fixture()
        let audio = Data(repeating: 6, count: 40)
        let urls = try LocalAudioArtifactFixture.seed(root: fixture.storeRoot, bookID: "book", chapters: [
            .init(index: 0, title: "Copy", retention: .downloaded, audio: audio),
            .init(index: 1, title: "Only copy", retention: .downloaded, audio: audio, playbackRetentionRequested: true),
            .init(index: 2, title: "Temporary", retention: .temporary, audio: audio)
        ])
        let converted = fixture.root.appendingPathComponent("converted.mp3")
        try await fixture.store.releaseDownload(bookID: "book", chapterIndex: 0, playbackSource: converted)
        try await fixture.store.releaseDownload(bookID: "book", chapterIndex: 1, playbackSource: urls[1])
        try await fixture.store.releaseDownload(bookID: "book", chapterIndex: 2, playbackSource: nil)
        try await fixture.store.releaseDownload(bookID: "book", chapterIndex: 9, playbackSource: nil)
        try await fixture.store.releaseDownload(bookID: "unknown", chapterIndex: 0, playbackSource: nil)

        let manifest = try XCTUnwrap(LocalAudioArtifactFixture.manifest(root: fixture.storeRoot, bookID: "book"))
        XCTAssertEqual(manifest.chapters[0].state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.canonical(0).path))
        XCTAssertEqual(manifest.chapters[1].state, .available)
        XCTAssertEqual(manifest.chapters[1].retention, .temporary)
        XCTAssertEqual(manifest.chapters[1].playbackRetentionRequested, false)
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(1)), audio, "The only copy stays playable")
        XCTAssertEqual(manifest.chapters[2].retention, .temporary)
        XCTAssertEqual(try Data(contentsOf: fixture.canonical(2)), audio, "Audio that was never a Download is untouched")
        let indices = try await fixture.store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(indices, [])
    }
}
