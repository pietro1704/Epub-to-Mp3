import XCTest
@testable import EpubToMp3

final class ReaderPlaybackIdentityTests: XCTestCase {
    private func reader(_ paths: [String]) -> EbookFulltext {
        EbookFulltext(jobId: "fixture", bookTitle: "Fixture", bookAuthor: nil,
            chapters: paths.enumerated().map { position, path in
                .init(index: position + 1, name: "Same title", sourcePath: path,
                      text: "Body", html: nil, css: nil, charCount: 4, segments: nil)
            })
    }

    private func metadata(_ paths: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chapters": paths.map { ["sourcePath": $0] }])
    }

    @MainActor
    func testPartialNativeSnapshotNeverInfersOneBasedIdentityFromMissingCover() throws {
        let data = Data(#"{"jobId":"native","state":"running","chapterIndexBase":0,"chapterProgress":[{"index":1,"name":"One"},{"index":2,"name":"Two"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: data)
        XCTAssertEqual(PlaybackSegmentSession.segmentManifestIndexOffset(snapshot), 0)
        XCTAssertEqual(PlaybackChapterQueue.chapterValue(snapshot: snapshot, playbackChapters: [],
            currentChapterIndex: 1, isSegmentMode: true)?.name, "One")
        XCTAssertEqual(PlaybackChapterQueue.nextCanonicalIndex(snapshot: snapshot, playbackChapters: [],
            currentChapterIndex: 1, isSegmentMode: true), 2)
        XCTAssertEqual(PlaybackChapterQueue.chapterValue(snapshot: snapshot, playbackChapters: [],
            currentChapterIndex: 2, isSegmentMode: true)?.name, "Two")
    }

    func testRealReaderAndBundledRustUseTheSameSourceIdentity() throws {
        let url = try EpubFixture.createWithChapters(["First source words.", "Second source words."])
        defer { try? FileManager.default.removeItem(at: url) }
        let fulltext = EpubFallbackParser.parse(url: url, bookId: "fixture")
        let structure = try ConverterFFIAdapter().openBook(at: url).metadataJSON
        let map = try ReaderConversionChapterMap(reader: fulltext, metadata: structure)
        XCTAssertEqual(try map.corePosition(for: fulltext.chapters[1].zeroBasedEpubIndex), 1)
        XCTAssertEqual(try map.readerPosition(for: 0), fulltext.chapters[0].zeroBasedEpubIndex)
    }

    @MainActor
    func testPlaybackWindowUsesConvertibleNeighboursAndPreservesCancellation() throws {
        let map = try ReaderConversionChapterMap(reader: reader(["cover.xhtml", "one.xhtml", "empty.xhtml", "two.xhtml"]),
            metadata: metadata(["one.xhtml", "two.xhtml"]))
        let control = try RustConversionCoordinator.makePlaybackControl()
        control.updatePlaybackWindow(currentChapter: 1, chaptersAhead: 1)
        control.installReaderChapterMap(map)
        XCTAssertTrue(control.contains(chapterIndex: 1))
        XCTAssertTrue(control.contains(chapterIndex: 3), "The next convertible chapter can skip a reader-only document")
        XCTAssertFalse(control.contains(chapterIndex: 2))
        XCTAssertFalse(control.prioritize(chapterIndex: 2))
        XCTAssertTrue(control.prioritize(chapterIndex: 3))
        control.cancel()
        XCTAssertTrue(control.isCancellationRequested)
        let replacement = try RustConversionCoordinator.makePlaybackControl()
        replacement.updatePlaybackWindow(currentChapter: 3, chaptersAhead: 0)
        XCTAssertTrue(replacement.contains(chapterIndex: 3))
        XCTAssertFalse(replacement.isCancellationRequested)
    }
}
