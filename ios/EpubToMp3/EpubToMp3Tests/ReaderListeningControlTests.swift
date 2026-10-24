import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

private final class ListeningWireCapture {
    var requests: [[String: Any]] = []
}

final class ReaderListeningControlTests: XCTestCase {
    func testPositionAndFeedbackKeepVersionSourceAndTextCoordinates() throws {
        let capture = ListeningWireCapture()
        let handle = Unmanaged.passUnretained(capture).toOpaque()
        let callback: ConverterJobControlJSON = { raw, json in
            guard let raw, let json,
                  let object = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else { return false }
            Unmanaged<ListeningWireCapture>.fromOpaque(UnsafeMutableRawPointer(mutating: raw)).takeUnretainedValue().requests.append(object)
            return true
        }
        let control = ConverterPlaybackControl(rawHandle: handle, free: { _ in }, cancel: { _ in },
            prioritize: { _, _ in true }, setWindow: { _, _, _ in }, windowContains: { _, _ in true },
            listeningPosition: callback, playbackFeedback: callback)
        let reader = EbookFulltext(jobId: "fixture", bookTitle: "Fixture", bookAuthor: nil, chapters: [
            .init(index: 1, name: "Body", sourcePath: "body.xhtml", text: "á🙂12345678", html: nil, css: nil, charCount: 10, segments: nil)
        ])
        let map = try ReaderConversionChapterMap(reader: reader, metadata: Data(#"{"chapters":[{"sourcePath":"body.xhtml","textChars":10}]}"#.utf8))
        control.updatePlaybackWindow(currentChapter: 0)
        control.startFromPage(ratio: 0.5)
        control.installReaderChapterMap(map)
        XCTAssertEqual(capture.requests.last?["version"] as? Int, 2)
        XCTAssertEqual(capture.requests.last?["chapter_index"] as? Int, 0)
        XCTAssertEqual(capture.requests.last?["text_offset"] as? Int, 5)
        control.sendPlaybackFeedback(chapter: 0, remaining: 12, rate: 2)
        XCTAssertEqual(capture.requests.last?["remaining_audio_seconds"] as? Double, 12)
        XCTAssertEqual(capture.requests.last?["playback_rate"] as? Double, 2)
        control.startFromPage(ratio: 1);
        XCTAssertEqual(capture.requests.last?["text_offset"] as? Int, 9,
            "A final page must retain source text instead of requesting an empty chapter suffix.")
        let count = capture.requests.count
        control.startFromPage(ratio: .nan)
        XCTAssertEqual(capture.requests.count, count)
    }

    func testCatalogAndCapturedSelectionKeepIndependentRuntimeAndModelRevision() throws {
        let catalog = try TtsCatalog.decode(Data(#"{"version":2,"models":[{"id":"a","engine":"piper","runtime":"piper","revision":"sha-a","languages":["pt"],"platforms":["Macos"]}]}"#.utf8))
        let selection = try XCTUnwrap(catalog.models.first?.selection())
        var options = ConversionOptions()
        options.ttsPreferences = TtsPreferences(primary: selection, secondary: nil, allowOnlineFallback: false, policyVersion: 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(options.encodedJSON().utf8)) as? [String: Any])
        XCTAssertEqual(json["contract_version"] as? Int, 2)
        XCTAssertEqual(selection.session?.modelRevision, "sha-a")
        XCTAssertThrowsError(try TtsCatalog.decode(Data(#"{"version":3,"models":[]}"#.utf8)))
    }
}
