#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class PreparedReaderCodecBenchmarkTests: XCTestCase {
    func testOptInPreparedAttributedChapterDecodeCostAndFidelity() async throws {
        struct Sample: Encodable {
            let book: String
            let chapter: Int
            let renderMilliseconds: Double
            let archiveBytes: Int
            let decodeMilliseconds: [Double]
        }
        let input = try NativePlaybackBenchmarkInput.optIn()
        let defaultsID = "PreparedAttributedChapter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsID))
        defer { defaults.removePersistentDomain(forName: defaultsID) }
        let settings = AppSettings(defaults: defaults)
        var samples: [Sample] = []
        for book in input.books {
            let payload = try await MacEpubParser.parse(at: URL(fileURLWithPath: book.sourcePath),
                                                        bookId: UUID().uuidString)
            guard payload.chapters.indices.contains(book.chapterStart) else {
                throw NativePlaybackBenchmarkInput.invalid("Requested prepared chapter is missing")
            }
            let chapter = payload.chapters[book.chapterStart]
            let startRender = ProcessInfo.processInfo.systemUptime
            let rendered = try XCTUnwrap(EpubHtmlRenderer.render(html: try XCTUnwrap(chapter.html),
                css: chapter.css, settings: settings, resources: chapter.resources))
            let attributed = NSAttributedString(rendered)
            let renderTime = (ProcessInfo.processInfo.systemUptime - startRender) * 1000
            let archive = try NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: true)
            var decodeTimes: [Double] = []
            for _ in 0..<3 {
                let startDecode = ProcessInfo.processInfo.systemUptime
                let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self,
                                                                               from: archive))
                decodeTimes.append((ProcessInfo.processInfo.systemUptime - startDecode) * 1000)
                XCTAssertTrue(restored.isEqual(to: attributed),
                              "Prepared restoration must preserve complete text and native attributes")
            }
            samples.append(Sample(book: book.name, chapter: book.chapterStart, renderMilliseconds: renderTime,
                                  archiveBytes: archive.count, decodeMilliseconds: decodeTimes))
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        attachment.name = "native-prepared-attributed-chapter-comparison.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOptInPreparedReaderCodecDecodeCost() async throws {
        struct Sample: Encodable {
            let book: String
            let jsonBytes: Int
            let binaryBytes: Int
            let jsonDecodeMilliseconds: [Double]
            let binaryDecodeMilliseconds: [Double]
        }
        let input = try NativePlaybackBenchmarkInput.optIn()
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]
        let binaryEncoder = PropertyListEncoder()
        binaryEncoder.outputFormat = .binary
        var samples: [Sample] = []
        for selection in input.books {
            let payload = try await MacEpubParser.parse(at: URL(fileURLWithPath: selection.sourcePath),
                                                        bookId: UUID().uuidString)
            let json = try jsonEncoder.encode(payload)
            let binary = try binaryEncoder.encode(payload)
            var jsonTimes: [Double] = [], binaryTimes: [Double] = []
            for _ in 0..<3 {
                let startJSON = ProcessInfo.processInfo.systemUptime
                let decodedJSON = try JSONDecoder().decode(EbookFulltext.self, from: json)
                jsonTimes.append((ProcessInfo.processInfo.systemUptime - startJSON) * 1000)
                let startBinary = ProcessInfo.processInfo.systemUptime
                let decodedBinary = try PropertyListDecoder().decode(EbookFulltext.self, from: binary)
                binaryTimes.append((ProcessInfo.processInfo.systemUptime - startBinary) * 1000)
                XCTAssertEqual(try jsonEncoder.encode(decodedJSON), json)
                XCTAssertEqual(try jsonEncoder.encode(decodedBinary), json,
                               "Codec comparison must preserve all chapter text, HTML, styles and resources")
            }
            samples.append(Sample(book: selection.name, jsonBytes: json.count, binaryBytes: binary.count,
                                  jsonDecodeMilliseconds: jsonTimes, binaryDecodeMilliseconds: binaryTimes))
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        attachment.name = "native-reader-codec-decode-comparison.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
