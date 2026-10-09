#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class PreparedReaderCodecBenchmarkTests: XCTestCase {
    func testOptInProjectionValidationVersusCatalogDecode() async throws {
        struct Sample: Encodable {
            let book: String
            let chapter: Int
            let sourceBytes: Int
            let sourceSHA256: String
            let projectionReadMilliseconds: [Double]
            let catalogDecodeMilliseconds: [Double]
            let catalogReadDecodeMilliseconds: [Double]
        }
        struct Report: Encodable {
            let platform: String
            let operatingSystem: String
            let limits: String
            let samples: [Sample]
        }
        let input = try NativePlaybackBenchmarkInput.optIn()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projection-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var samples: [Sample] = []
        for (index, selection) in input.books.enumerated() {
            let id = "projection-\(UUID().uuidString)"
            let payload = try await MacEpubParser.parse(at: URL(fileURLWithPath: selection.sourcePath), bookId: id)
            guard payload.chapters.indices.contains(selection.chapterStart) else {
                throw NativePlaybackBenchmarkInput.invalid("Selected reader chapter is missing")
            }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let bytes = try encoder.encode(payload)
            let source = root.appendingPathComponent("source-\(index).plist")
            try bytes.write(to: source, options: .atomic)
            let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters-\(index)"))
            try await store.write(bookID: id, chapterOrdinal: selection.chapterStart, fulltextURL: source)
            var projectionTimes: [Double] = [], catalogTimes: [Double] = [], readDecodeTimes: [Double] = []
            for _ in 0..<3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let projection = await store.read(bookID: id, chapterOrdinal: selection.chapterStart, fulltextURL: source)
                projectionTimes.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                XCTAssertEqual(try XCTUnwrap(projection).chapter, payload.chapters[selection.chapterStart])
                XCTAssertEqual(projection?.title, payload.bookTitle)
                XCTAssertEqual(projection?.author, payload.bookAuthor)
                XCTAssertEqual(projection?.toc, payload.toc)
                let result = try await Task.detached(priority: .userInitiated) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let decoded = try PropertyListDecoder().decode(EbookFulltext.self, from: bytes)
                    return (decoded, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                }.value
                catalogTimes.append(result.1)
                XCTAssertEqual(result.0, payload)
                let readResult = try await Task.detached(priority: .userInitiated) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let loaded = try Data(contentsOf: source)
                    let decoded = try PropertyListDecoder().decode(EbookFulltext.self, from: loaded)
                    return (decoded, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                }.value
                readDecodeTimes.append(readResult.1)
                XCTAssertEqual(readResult.0, payload)
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            samples.append(.init(book: selection.name, chapter: selection.chapterStart, sourceBytes: bytes.count,
                sourceSHA256: selection.sourceSHA256, projectionReadMilliseconds: projectionTimes,
                catalogDecodeMilliseconds: catalogTimes, catalogReadDecodeMilliseconds: readDecodeTimes))
        }
        let report = Report(platform: "native macOS Debug", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            limits: "Three samples, sequential alternating routes; OS caches not flushed; excludes parsing/setup, rendering, position and controls. Projection includes both SHA passes; decode-only uses loaded Data; read/decode includes file IO.", samples: samples)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(report), uniformTypeIdentifier: "public.json")
        attachment.name = "native-projection-validation-versus-catalog-decode.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
