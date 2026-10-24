import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderConversionChapterMapTests: XCTestCase {
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

    func testExtraReaderCoverAndSparseCoreChaptersDoNotShiftRequestedSource() throws {
        let map = try ReaderConversionChapterMap(
            reader: reader(["cover.xhtml", "title.xhtml", "one.xhtml", "two.xhtml", "three.xhtml"]),
            metadata: metadata(["title.xhtml", "one.xhtml", "three.xhtml"]))
        XCTAssertEqual(try map.corePosition(for: 2), 1)
        XCTAssertEqual(try map.readerPosition(for: 2), 4)
        XCTAssertThrowsError(try map.corePosition(for: 0))
        XCTAssertThrowsError(try map.corePosition(for: 3))
        XCTAssertThrowsError(try map.readerPosition(for: 3))
    }

    func testSameTitlesResolveBySourceAndReorderedStructuresFailSafely() throws {
        let map = try ReaderConversionChapterMap(reader: reader(["one.xhtml", "two.xhtml"]),
            metadata: metadata(["one.xhtml", "two.xhtml"]))
        XCTAssertEqual(try map.corePosition(for: 1), 1)
        XCTAssertThrowsError(try ReaderConversionChapterMap(reader: reader(["one.xhtml", "two.xhtml"]),
            metadata: metadata(["two.xhtml", "one.xhtml"])))
    }

    func testStaleAndAmbiguousStructuresFailBeforeSynthesis() throws {
        XCTAssertThrowsError(try ReaderConversionChapterMap(reader: reader(["old.xhtml"]),
            metadata: metadata(["new.xhtml"])))
        XCTAssertThrowsError(try ReaderConversionChapterMap(reader: reader(["same.xhtml", "same.xhtml"]),
            metadata: metadata(["same.xhtml"])))
        XCTAssertThrowsError(try ReaderConversionChapterMap(reader: reader(["same.xhtml"]),
            metadata: metadata(["same.xhtml", "same.xhtml"])))
        for json in [#"{"coreToReader":{"0":1,"1":1}}"#, #"{"coreToReader":{"0":-1}}"#,
                     #"{"coreToReader":{"1":0}}"#, #"{"coreToReader":{"0":2,"1":0}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ReaderConversionChapterMap.self, from: Data(json.utf8)))
        }
    }

    func testEventsManifestAndRelaunchKeepReaderAxisAndJobIdentity() throws {
        let map = try ReaderConversionChapterMap(reader: reader(["cover.xhtml", "one.xhtml", "two.xhtml"]),
            metadata: metadata(["one.xhtml", "two.xhtml"]))
        let restored = try JSONDecoder().decode(ReaderConversionChapterMap.self, from: JSONEncoder().encode(map))
        let event = Data(#"{"jobId":"active","chapterIndex":1,"engine":"system","voice":"Fixture"}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: restored.event(event)) as? [String: Any])
        XCTAssertEqual(object["chapterIndex"] as? Int, 2)
        XCTAssertEqual(object["jobId"] as? String, "active")
        XCTAssertEqual(object["voice"] as? String, "Fixture")
        let manifest = Data(#"{"manifest":{"jobId":"active","chapters":[{"sourceIndex":1,"filename":"two.mp3"}]}}"#.utf8)
        let projected = try XCTUnwrap(JSONSerialization.jsonObject(with: restored.manifest(manifest)) as? [String: Any])
        let content = try XCTUnwrap(projected["manifest"] as? [String: Any])
        let chapters = try XCTUnwrap(content["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.first?["sourceIndex"] as? Int, 2)
        XCTAssertEqual(content["jobId"] as? String, "active")
        XCTAssertThrowsError(try restored.event(Data(#"{"chapterIndex":99}"#.utf8)))
        XCTAssertThrowsError(try restored.manifest(Data(#"{"manifest":{"chapters":[{}]}}"#.utf8)))
    }

}
