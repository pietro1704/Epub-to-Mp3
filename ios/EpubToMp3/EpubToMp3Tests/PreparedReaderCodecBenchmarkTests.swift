#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class PreparedReaderCodecBenchmarkTests: XCTestCase {
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
