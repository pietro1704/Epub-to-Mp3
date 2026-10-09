import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import EpubToMp3

private struct DeviceBenchmarkSpec: Codable {
    struct Selection: Codable, Sendable {
        let bookPath: String
        let chapterStart: Int
        let chapterEnd: Int
        let jobID: String
    }

    let schemaVersion: Int
    let inputBase: String
    let runID: String
    let wholeBook: Bool
    let cases: [Selection]

    static func decode(_ json: String, temporaryRoot: URL) throws -> Self {
        let spec = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try spec.validate(temporaryRoot: temporaryRoot)
        return spec
    }

    func validate(temporaryRoot: URL) throws {
        try require(schemaVersion == 2, "Unsupported benchmark schema.")
        try require(inputBase == "temporary", "Benchmark inputs require temporary storage.")
        try require(UUID(uuidString: runID) != nil, "Invalid run UUID.")
        try require(!cases.isEmpty, "At least one explicit case is required.")
        var jobs = Set<UUID>()
        var bookPaths = Set<String>()
        let directory = stagedDirectory(temporaryRoot: temporaryRoot)
        try require(directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path,
                    "The staged run directory must not traverse symlinks.")
        for selection in cases {
            guard let job = UUID(uuidString: selection.jobID) else {
                throw BenchmarkFailure("Invalid job UUID.")
            }
            try require(jobs.insert(job).inserted, "Duplicate job UUID.")
            try require(bookPaths.insert(selection.bookPath).inserted,
                        "Duplicate book path would bypass the per-book chapter cap.")
            let parts = selection.bookPath.components(separatedBy: "/")
            try require(parts.count == 4 && Array(parts.prefix(3)) == ["EpubToMp3", "DeviceTestInputs", runID],
                        "Book path must belong directly to this staged run directory.")
            try require(!parts.contains("..") && !parts.contains(".") && !parts.contains("")
                        && !selection.bookPath.contains("\\") && !selection.bookPath.contains("%")
                        && !selection.bookPath.contains("\0"), "Unsafe staged book path.")
            let book = temporaryRoot.appendingPathComponent(selection.bookPath)
            try require(book.pathExtension.lowercased() == "epub"
                        && book.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                        "Staged EPUB escapes the run directory.")
            if selection.chapterStart == -1 && selection.chapterEnd == -1 {
                try require(wholeBook, "Whole-book selection requires explicit opt-in.")
            } else {
                try require(selection.chapterStart >= 0 && selection.chapterEnd >= selection.chapterStart
                            && selection.chapterEnd <= Int(Int32.max)
                            && selection.chapterEnd - selection.chapterStart <= 1,
                            "Select one or two inclusive zero-based chapters.")
            }
        }
    }

    func stagedDirectory(temporaryRoot: URL) -> URL {
        temporaryRoot.appendingPathComponent("EpubToMp3/DeviceTestInputs/\(runID)", isDirectory: true)
    }
}

private struct BenchmarkFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BenchmarkFailure(message) }
}

// Redirect only the benchmark coordinator's existing FileManager dependency.
private final class BenchmarkFileManager: FileManager, @unchecked Sendable {
    let supportRoot: URL

    init(supportRoot: URL) {
        self.supportRoot = supportRoot
        super.init()
    }

    override func url(for directory: FileManager.SearchPathDirectory,
                      in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        if directory == .applicationSupportDirectory && domain == .userDomainMask {
            return supportRoot
        }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }
}

private func validateBenchmarkOutputParent(_ output: URL) throws {
    let parent = output.deletingLastPathComponent().standardizedFileURL
    // URL equality also compares directory hints; resolving a missing directory
    // drops its trailing slash. Compare filesystem paths while rejecting symlinks.
    try require(parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path,
                "Unsafe output directory.")
}

private struct BenchmarkInputCopies {
    let directory: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("device-benchmark-\(UUID().uuidString)", isDirectory: true)
        let reserved = directory.path.withCString { mkdir($0, mode_t(0o700)) }
        try require(reserved == 0, "Could not reserve app-owned benchmark inputs (errno=\(errno)).")
    }

    func copy(source: URL, index: Int) throws -> URL {
        try require(try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                    "Staged benchmark input is not a regular file.")
        let destination = directory.appendingPathComponent("book-\(index).epub")
        // Write fresh bytes rather than inheriting service-owned permissions or metadata.
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        return destination
    }
}

private struct BenchmarkFootprintSample: Encodable {
    let physicalFootprintBytes: UInt64?
    let memoryStatus: Int32

    static func capture() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Self(physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
                    memoryStatus: status)
    }
}

private struct BenchmarkConversionMeasurements: Encodable {
    let semantics = "Client monotonic callback delivery of a published chapter MP3, not acoustic playback; process footprint point samples, not peak. Missing optional values are unmeasured."
    var beforeSynthesis: BenchmarkFootprintSample?
    var afterSynthesis: BenchmarkFootprintSample?
    var firstPlayableChapterDeliverySeconds: Double?
    var firstPlayableChapterIndex: Int?
    var rejectedChapterDeliveries: [String] = []
}

private func chapterDeliveryRejection(
    _ event: RustConversionCoordinator.ChapterCompletionEvent,
    jobID: String, start: Int, end: Int, output: URL, manager: FileManager
) -> String? {
    guard event.jobId == jobID else { return "job ID mismatch" }
    guard event.chapterIndex >= 0,
          start == -1 || (start...end).contains(event.chapterIndex) else { return "chapter outside requested range" }
    let audio = event.audioPath.resolvingSymlinksInPath().standardizedFileURL
    guard audio.deletingLastPathComponent().path == output.standardizedFileURL.path else { return "audio parent outside owned output" }
    guard audio.pathExtension.lowercased() == "mp3" else { return "audio extension is not MP3" }
    guard manager.isReadableFile(atPath: audio.path) else { return "audio file is not readable" }
    return nil
}

@MainActor
private final class BenchmarkDeliveryRecorder {
    let startedAt: UInt64
    var measurements: BenchmarkConversionMeasurements

    init(startedAt: UInt64, before: BenchmarkFootprintSample) {
        self.startedAt = startedAt
        measurements = BenchmarkConversionMeasurements(beforeSynthesis: before)
    }

    /// Record only the first delivery, using the same monotonic clock as native latency helpers.
    func record(chapterIndex: Int, deliveredAt: UInt64) -> Bool {
        guard measurements.firstPlayableChapterIndex == nil, deliveredAt >= startedAt else { return false }
        measurements.firstPlayableChapterIndex = chapterIndex
        measurements.firstPlayableChapterDeliverySeconds = Double(deliveredAt - startedAt) / 1_000_000_000
        return true
    }
}

private struct DeviceBenchmarkReport: Encodable {
    struct Case: Encodable {
        struct CacheReuse: Encodable {
            let audio = false
            let parsedText = "not_measured"
        }
        let bookPath: String
        let chapterStart: Int
        let chapterEnd: Int
        var engine: String?
        var voice: String?
        var language: String?
        var error: String?
        var chaptersRequested = 0
        var chaptersCompleted = 0
        var characters = 0
        var synthesisSeconds = 0.0
        var verificationSeconds = 0.0
        var audioDurationSeconds = 0.0
        var retryAttempts = 0
        var throttles = 0
        let cacheReuse = CacheReuse()
        var chunkMetrics: [String] = []
        var conversionMeasurements = BenchmarkConversionMeasurements()

        private enum CodingKeys: String, CodingKey {
            case bookPath, chapterStart, chapterEnd, engine, voice, language, error
            case chaptersRequested, chaptersCompleted, characters, synthesisSeconds, verificationSeconds
            case audioDurationSeconds, retryAttempts, throttles, cacheReuse, chunkMetrics
            case conversionMeasurements
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bookPath, forKey: .bookPath)
            try container.encode(chapterStart, forKey: .chapterStart)
            try container.encode(chapterEnd, forKey: .chapterEnd)
            // Preserve explicit nulls when the snapshot does not expose provider metadata.
            try container.encode(engine, forKey: .engine)
            try container.encode(voice, forKey: .voice)
            try container.encode(language, forKey: .language)
            try container.encode(error, forKey: .error)
            try container.encode(chaptersRequested, forKey: .chaptersRequested)
            try container.encode(chaptersCompleted, forKey: .chaptersCompleted)
            try container.encode(characters, forKey: .characters)
            try container.encode(synthesisSeconds, forKey: .synthesisSeconds)
            try container.encode(verificationSeconds, forKey: .verificationSeconds)
            try container.encode(audioDurationSeconds, forKey: .audioDurationSeconds)
            try container.encode(retryAttempts, forKey: .retryAttempts)
            try container.encode(throttles, forKey: .throttles)
            try container.encode(cacheReuse, forKey: .cacheReuse)
            try container.encode(chunkMetrics, forKey: .chunkMetrics)
            try container.encode(conversionMeasurements, forKey: .conversionMeasurements)
        }

        mutating func readTelemetry(output: URL) throws {
            let log = try String(contentsOf: output.appendingPathComponent("conversion.log"), encoding: .utf8)
            chunkMetrics = log.components(separatedBy: .newlines).filter { $0.contains("tts chunk=") }
            retryAttempts = chunkMetrics.filter { Self.result($0)?.hasPrefix("pressure:") == true }.count
            throttles = chunkMetrics.filter { Self.result($0) == "pressure:Throttle" }.count
        }

        static func result(_ line: String) -> String? {
            line.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("result=") }
                .map { String($0.dropFirst("result=".count)) }
        }
    }
    let schemaVersion = 1
    let runID: String
    var status = "failed"
    var cases: [Case]
    var error: String?
    var errors: [String] = []

    mutating func recordFailure(_ failure: Error, context: String, caseIndex: Int? = nil) {
        let message = failure.localizedDescription
        if error == nil { error = message }
        if let caseIndex, cases[caseIndex].error == nil { cases[caseIndex].error = message }
        let native = failure as NSError
        errors.append("\(context): \(message) [\(native.domain) code=\(native.code)] \(native)")
        status = "failed"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func save(to url: URL) throws -> Data {
        let data = try encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }
}

final class DeviceConversionBenchmarkTests: XCTestCase {
    @MainActor
    func testOptInDeviceConversionBenchmark() async throws {
        guard let json = ProcessInfo.processInfo.environment["EPUB2MP3_DEVICE_BENCHMARK_SPEC"] else {
            throw XCTSkip("Set EPUB2MP3_DEVICE_BENCHMARK_SPEC to an explicit benchmark JSON specification.")
        }
        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory.resolvingSymlinksInPath()
        let spec = try JSONDecoder().decode(DeviceBenchmarkSpec.self, from: Data(json.utf8))
        try require(UUID(uuidString: spec.runID) != nil, "Invalid report run UUID.")
        let reportURL = temporaryRoot.appendingPathComponent("DeviceBenchmarkReports/\(spec.runID).json")
        var report = DeviceBenchmarkReport(runID: spec.runID, cases: spec.cases.map {
            .init(bookPath: $0.bookPath, chapterStart: $0.chapterStart, chapterEnd: $0.chapterEnd)
        })
        var createdOutputs: [URL] = []
        var ownedInputs: BenchmarkInputCopies?
        var activeCase: Int?
        var phase = "scope validation"
        defer {
            for directory in createdOutputs {
                do { try manager.removeItem(at: directory) }
                catch {
                    report.recordFailure(error, context: "Output cleanup: \(directory.path)")
                    XCTFail("Could not remove benchmark output: \(error)")
                }
            }
            if let ownedInputs {
                do { try manager.removeItem(at: ownedInputs.directory) }
                catch {
                    report.recordFailure(error, context: "App-owned input cleanup")
                    XCTFail("Could not remove app-owned benchmark inputs: \(error)")
                }
            }
            do {
                _ = try report.save(to: reportURL)
            } catch {
                report.recordFailure(error, context: "Report persistence")
                XCTFail("Could not persist benchmark report: \(error)")
            }
            do {
                let data = try report.encoded()
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "device-benchmark-report.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch {
                XCTFail("Could not attach benchmark report: \(error)")
            }
        }
        do {
            _ = try report.save(to: reportURL)
            try spec.validate(temporaryRoot: temporaryRoot)
            let copies = try BenchmarkInputCopies()
            ownedInputs = copies
            var bookURLs: [URL] = []
            let adapter = ConverterFFIAdapter()
            let isolatedManager = BenchmarkFileManager(supportRoot: copies.directory)
            let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: isolatedManager)
            let outputs = spec.cases.map {
                copies.directory.appendingPathComponent("EpubToMp3/RustConversions/\($0.jobID)", isDirectory: true)
            }
            // Preflight every case before the first synthesis, including metadata bounds.
            for (index, selection) in spec.cases.enumerated() {
                activeCase = index
                phase = "input copy and metadata preflight"
                let source = temporaryRoot.appendingPathComponent(selection.bookPath)
                try require(manager.isReadableFile(atPath: source.path), "Staged EPUB is unreadable: \(selection.bookPath)")
                let bookURL = try copies.copy(source: source, index: index)
                bookURLs.append(bookURL)
                let output = outputs[index]
                try require(!manager.fileExists(atPath: output.path)
                            && (try? manager.destinationOfSymbolicLink(atPath: output.path)) == nil,
                            "Benchmark output already exists; audio reuse is forbidden.")
                try validateBenchmarkOutputParent(output)
                let book = try adapter.openBook(at: bookURL)
                let metadata = try JSONSerialization.jsonObject(with: book.metadataJSON) as? [String: Any]
                guard let chapters = metadata?["chapters"] as? [[String: Any]], !chapters.isEmpty else {
                    throw BenchmarkFailure("Missing chapter metadata.")
                }
                if selection.chapterStart == -1 {
                    report.cases[index].chaptersRequested = chapters.count
                } else {
                    try require(selection.chapterEnd < chapters.count, "Selected range exceeds book metadata.")
                    report.cases[index].chaptersRequested = selection.chapterEnd - selection.chapterStart + 1
                }
            }
            _ = try report.save(to: reportURL)
            for (index, selection) in spec.cases.enumerated() {
                activeCase = index
                phase = "output reservation"
                let output = outputs[index]
                // Reserve a fresh directory ourselves so failure cleanup has exact ownership.
                try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let reserved = output.path.withCString { mkdir($0, mode_t(0o700)) }
                try require(reserved == 0, "Could not exclusively reserve a fresh output job directory (errno=\(errno)).")
                createdOutputs.append(output)
                print("[Device benchmark] starting book=\(selection.bookPath) chapters=\(report.cases[index].chaptersRequested)")
                let beforeSynthesis = BenchmarkFootprintSample.capture()
                let delivery = BenchmarkDeliveryRecorder(startedAt: DispatchTime.now().uptimeNanoseconds,
                                                         before: beforeSynthesis)
                let firstDelivery = expectation(description: "First published chapter delivered for case \(index)")
                let synthesisStart = ProcessInfo.processInfo.systemUptime
                phase = "conversion"
                let result: RustConversionCoordinator.Result
                do {
                    result = try await coordinator.convert(
                        bookURL: bookURLs[index], jobID: selection.jobID,
                        chapterStart: Int32(selection.chapterStart), chapterEnd: Int32(selection.chapterEnd),
                        onProgress: { event in
                            print("[Device benchmark] book=\(selection.bookPath) completed=\(event.chaptersCompleted)/\(event.chaptersTotal) \(event.message)")
                        },
                        onChapterCompleted: { event in
                            let deliveredAt = DispatchTime.now().uptimeNanoseconds
                            if let reason = chapterDeliveryRejection(event, jobID: selection.jobID,
                                start: selection.chapterStart, end: selection.chapterEnd,
                                output: output, manager: manager) {
                                delivery.measurements.rejectedChapterDeliveries.append(reason)
                                print("[Device benchmark] rejected chapter=\(event.chapterIndex): \(reason)")
                                return
                            }
                            if delivery.record(chapterIndex: event.chapterIndex, deliveredAt: deliveredAt) {
                                firstDelivery.fulfill()
                            }
                        }
                    )
                } catch {
                    report.cases[index].synthesisSeconds = ProcessInfo.processInfo.systemUptime - synthesisStart
                    delivery.measurements.afterSynthesis = BenchmarkFootprintSample.capture()
                    report.cases[index].conversionMeasurements = delivery.measurements
                    report.cases[index].error = error.localizedDescription
                    try? report.cases[index].readTelemetry(output: output)
                    throw error
                }
                report.cases[index].synthesisSeconds = ProcessInfo.processInfo.systemUptime - synthesisStart
                delivery.measurements.afterSynthesis = BenchmarkFootprintSample.capture()
                // The coordinator dispatches callbacks to MainActor tasks; drain delivery
                // independently of synthesis timing before snapshotting measurements.
                phase = "chapter delivery"
                await fulfillment(of: [firstDelivery], timeout: 2)
                report.cases[index].conversionMeasurements = delivery.measurements
                try require(delivery.measurements.firstPlayableChapterIndex != nil,
                            "Missing published chapter delivery callback; rejected=\(delivery.measurements.rejectedChapterDeliveries).")
                _ = try report.save(to: reportURL)
                let verificationStart = ProcessInfo.processInfo.systemUptime
                phase = "audio verification"
                do {
                    let snapshot = try result.snapshot()
                    report.cases[index].engine = snapshot.engine
                    report.cases[index].voice = snapshot.voice
                    report.cases[index].language = snapshot.language
                    report.cases[index].chaptersCompleted = snapshot.chaptersCompleted ?? 0
                    report.cases[index].characters = snapshot.playableChapters.reduce(0) { $0 + ($1.chars ?? 0) }
                    try report.cases[index].readTelemetry(output: output)
                    try require(!report.cases[index].chunkMetrics.isEmpty, "Missing chunk telemetry.")
                    let expected = report.cases[index].chaptersRequested
                    try require(snapshot.state == "finished", "Conversion did not finish.")
                    try require(snapshot.chaptersTotal == expected && snapshot.chaptersCompleted == expected
                                && snapshot.playableChapters.count == expected, "Requested chapter count was not completed.")
                    let indices = selection.chapterStart == -1 ? Array(0..<expected)
                        : Array(selection.chapterStart...selection.chapterEnd)
                    try require(snapshot.playableChapters.map(\.index) == indices, "Unexpected source chapter indices.")
                    try require(indices.contains(try XCTUnwrap(delivery.measurements.firstPlayableChapterIndex)),
                                "Delivered chapter was not part of the verified selection.")
                    try require(result.outputDirectory.standardizedFileURL == output.standardizedFileURL,
                                "Unexpected output job directory.")
                    var verifiedPaths = Set<String>()
                    for chapter in snapshot.playableChapters {
                        let path = try XCTUnwrap(chapter.downloadUrl)
                        let audio = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                        try require(audio.deletingLastPathComponent() == output.standardizedFileURL
                                    && audio.pathExtension.lowercased() == "mp3"
                                    && verifiedPaths.insert(audio.path).inserted, "Unexpected or duplicate MP3 artifact.")
                        let asset = AVURLAsset(url: audio)
                        let playable = try await asset.load(.isPlayable)
                        let duration = try await asset.load(.duration).seconds
                        try require(playable && duration.isFinite && duration > 0, "MP3 is not playable with positive duration.")
                        report.cases[index].audioDurationSeconds += duration
                    }
                } catch {
                    report.cases[index].verificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStart
                    throw error
                }
                report.cases[index].verificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStart
                _ = try report.save(to: reportURL)
                print("[Device benchmark] verified book=\(selection.bookPath) synthesis=\(report.cases[index].synthesisSeconds)s verification=\(report.cases[index].verificationSeconds)s")
            }
            report.status = "passed"
        } catch {
            report.recordFailure(error, context: phase, caseIndex: activeCase)
            print("[Device benchmark] failed phase=\(phase) error=\(error)")
            throw error
        }
    }

    private let validationRoot = URL(fileURLWithPath: "/device-benchmark-unit-tests", isDirectory: true)

    private func specification(start: Int = 4, end: Int = 5, wholeBook: Bool = false) -> DeviceBenchmarkSpec {
        let run = UUID().uuidString
        return .init(schemaVersion: 2, inputBase: "temporary", runID: run, wholeBook: wholeBook, cases: [
            .init(bookPath: "EpubToMp3/DeviceTestInputs/\(run)/book-0.epub",
                  chapterStart: start, chapterEnd: end, jobID: UUID().uuidString)
        ])
    }

    func testScopeAcceptsOneAndTwoChapters() throws {
        try specification(start: 0, end: 0).validate(temporaryRoot: validationRoot)
        try specification().validate(temporaryRoot: validationRoot)
    }

    func testScopeRejectsOversizedReversedAndMixedSentinels() {
        for (start, end) in [(0, 2), (5, 4), (-1, 0), (0, -1), (-2, -2), (Int.max, Int.max)] {
            for wholeBook in [false, true] {
                XCTAssertThrowsError(try specification(start: start, end: end, wholeBook: wholeBook)
                    .validate(temporaryRoot: validationRoot))
            }
        }
    }

    func testScopeRequiresExplicitWholeBookOptIn() throws {
        XCTAssertThrowsError(try specification(start: -1, end: -1).validate(temporaryRoot: validationRoot))
        try specification(start: -1, end: -1, wholeBook: true).validate(temporaryRoot: validationRoot)
    }

    func testScopeRejectsMalformedMissingAndUnsupportedSchema() throws {
        let valid = try JSONEncoder().encode(specification())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for key in ["schemaVersion", "inputBase", "runID", "wholeBook", "cases"] {
            var missing = object
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            XCTAssertThrowsError(try DeviceBenchmarkSpec.decode(String(decoding: data, as: UTF8.self), temporaryRoot: validationRoot))
        }
        object["schemaVersion"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try DeviceBenchmarkSpec.decode(String(decoding: data, as: UTF8.self), temporaryRoot: validationRoot))
        XCTAssertThrowsError(try DeviceBenchmarkSpec.decode("{", temporaryRoot: validationRoot))
    }

    func testScopeRejectsTraversalAndOtherRunPaths() {
        let spec = specification()
        for path in ["/tmp/book.epub", "EpubToMp3/DeviceTestInputs/\(spec.runID)/../book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/%2e%2e.epub",
                     "EpubToMp3/DeviceTestInputs/\(UUID().uuidString)/book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/nested/book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/book\\other.epub"] {
            let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: [
                .init(bookPath: path, chapterStart: 0, chapterEnd: 1, jobID: UUID().uuidString)
            ])
            XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot), path)
        }
    }

    func testScopeRejectsEmptyCasesInvalidUUIDsAndDuplicateJobs() {
        let spec = specification()
        for invalid in [
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: []),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: "invalid", wholeBook: false, cases: spec.cases),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: spec.cases + spec.cases),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: [
                .init(bookPath: spec.cases[0].bookPath, chapterStart: 0, chapterEnd: 0, jobID: "invalid")
            ])
        ] {
            XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot))
        }
    }

    func testScopeRejectsDuplicateBookPathsWithDistinctJobsAndDisjointRanges() {
        let spec = specification(start: 0, end: 1)
        let duplicate = DeviceBenchmarkSpec.Selection(
            bookPath: spec.cases[0].bookPath, chapterStart: 2, chapterEnd: 3,
            jobID: UUID().uuidString
        )
        XCTAssertNotEqual(spec.cases[0].jobID, duplicate.jobID)
        let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false,
                                          cases: spec.cases + [duplicate])
        XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot)) { error in
            XCTAssertEqual((error as? BenchmarkFailure)?.description,
                           "Duplicate book path would bypass the per-book chapter cap.")
        }
    }

    func testReportIncludesProviderMetadataAndExplicitNulls() throws {
        var entry = DeviceBenchmarkReport.Case(bookPath: "book.epub", chapterStart: 0, chapterEnd: 1)
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["engine", "voice", "language"] {
            XCTAssertTrue(empty[key] is NSNull, key)
        }
        entry.engine = "edge"
        entry.voice = "en-US-AriaNeural"
        entry.language = "en-US"
        let populated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(populated["engine"] as? String, entry.engine)
        XCTAssertEqual(populated["voice"] as? String, entry.voice)
        XCTAssertEqual(populated["language"] as? String, entry.language)
    }

    func testFootprintCaptureReportsNativeStatusAndPositiveBytes() throws {
        let sample = BenchmarkFootprintSample.capture()
        XCTAssertEqual(sample.memoryStatus, KERN_SUCCESS)
        guard sample.memoryStatus == KERN_SUCCESS else { return }
        let bytes = try XCTUnwrap(sample.physicalFootprintBytes)
        XCTAssertGreaterThan(bytes, 0)
    }

    @MainActor
    func testDeliveryMetricKeepsFirstChapterAndMonotonicElapsedTime() {
        let recorder = BenchmarkDeliveryRecorder(startedAt: 1_000_000_000,
            before: .init(physicalFootprintBytes: 4096, memoryStatus: KERN_SUCCESS))
        XCTAssertFalse(recorder.record(chapterIndex: 4, deliveredAt: 999_999_999))
        XCTAssertNil(recorder.measurements.firstPlayableChapterDeliverySeconds)
        XCTAssertTrue(recorder.record(chapterIndex: 5, deliveredAt: 1_250_000_000))
        XCTAssertFalse(recorder.record(chapterIndex: 4, deliveredAt: 2_000_000_000))
        XCTAssertEqual(recorder.measurements.firstPlayableChapterIndex, 5)
        XCTAssertEqual(recorder.measurements.firstPlayableChapterDeliverySeconds, 0.25)
    }

    func testReportAddsFootprintAndDeliveryWithoutChangingExistingSchema() throws {
        var entry = DeviceBenchmarkReport.Case(bookPath: "fixture.epub", chapterStart: 4, chapterEnd: 5)
        entry.conversionMeasurements.beforeSynthesis = .init(physicalFootprintBytes: 8192, memoryStatus: KERN_SUCCESS)
        entry.conversionMeasurements.afterSynthesis = .init(physicalFootprintBytes: 4096, memoryStatus: KERN_SUCCESS)
        entry.conversionMeasurements.firstPlayableChapterDeliverySeconds = 0.25
        entry.conversionMeasurements.firstPlayableChapterIndex = 4
        let report = DeviceBenchmarkReport(runID: UUID().uuidString, cases: [entry])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases[0]["chapterStart"] as? Int, 4)
        XCTAssertEqual(cases[0]["chapterEnd"] as? Int, 5)
        XCTAssertEqual(cases[0]["synthesisSeconds"] as? Double, 0)
        XCTAssertTrue(cases[0]["engine"] is NSNull)
        let metrics = try XCTUnwrap(cases[0]["conversionMeasurements"] as? [String: Any])
        let before = try XCTUnwrap(metrics["beforeSynthesis"] as? [String: Any])
        let after = try XCTUnwrap(metrics["afterSynthesis"] as? [String: Any])
        XCTAssertEqual(before["physicalFootprintBytes"] as? UInt64, 8192)
        XCTAssertEqual(after["physicalFootprintBytes"] as? UInt64, 4096)
        XCTAssertEqual(metrics["firstPlayableChapterDeliverySeconds"] as? Double, 0.25)
        XCTAssertEqual(metrics["firstPlayableChapterIndex"] as? Int, 4)
        XCTAssertTrue(try XCTUnwrap(metrics["semantics"] as? String).contains("not acoustic"))
    }

    func testReportDoesNotInventMissingDeliveryOrUnavailableFootprint() throws {
        var metrics = BenchmarkConversionMeasurements()
        metrics.beforeSynthesis = .init(physicalFootprintBytes: nil, memoryStatus: KERN_FAILURE)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any])
        XCTAssertNil(object["firstPlayableChapterDeliverySeconds"])
        XCTAssertNil(object["firstPlayableChapterIndex"])
        XCTAssertNil(object["afterSynthesis"])
        let before = try XCTUnwrap(object["beforeSynthesis"] as? [String: Any])
        XCTAssertNil(before["physicalFootprintBytes"])
        XCTAssertEqual(before["memoryStatus"] as? Int32, KERN_FAILURE)
    }

    func testReportPreservesConversionErrorWhenCleanupAlsoFails() throws {
        var report = DeviceBenchmarkReport(runID: UUID().uuidString, cases: [
            .init(bookPath: "book.epub", chapterStart: 0, chapterEnd: 1)
        ])
        let original = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSLocalizedDescriptionKey: "Original conversion failure",
            NSFilePathErrorKey: "/staged/run/Contents/PkgInfo",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2)
        ])
        report.recordFailure(original, context: "conversion", caseIndex: 0)
        report.recordFailure(NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "Secondary cleanup failure"
        ]), context: "output cleanup")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["error"] as? String, original.localizedDescription)
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases[0]["error"] as? String, original.localizedDescription)
        let errors = try XCTUnwrap(object["errors"] as? [String])
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors[0].contains("Contents/PkgInfo"))
        XCTAssertTrue(errors[0].contains("code=260"))
        XCTAssertTrue(errors[1].contains("code=513"))
    }

    func testAppOwnedInputCopiesLeaveStagedSourcesUntouched() throws {
        let fixture = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = fixture.directory.appendingPathComponent("staged.epub")
        let contents = Data("Offline staged source fixture".utf8)
        try contents.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let copies = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: copies.directory) }
        let copied = try copies.copy(source: source, index: 0)
        XCTAssertNotEqual(copied.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: copied), contents)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: copied.path))
        try FileManager.default.removeItem(at: copies.directory)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testOutputParentAcceptsMissingDirectoriesButRejectsSymlinks() throws {
        let owned = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let output = owned.directory.appendingPathComponent("EpubToMp3/RustConversions/\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
        XCTAssertNoThrow(try validateBenchmarkOutputParent(output))
        let target = owned.directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = owned.directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try validateBenchmarkOutputParent(link.appendingPathComponent("job", isDirectory: true)))
    }

    @MainActor
    func testChapterDeliveryRejectionExplainsEveryGuardWithoutNetwork() throws {
        let owned = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let output = owned.directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let audio = output.appendingPathComponent("chapter #8?.mp3")
        try Data("readable delivery fixture".utf8).write(to: audio)
        func event(job: String = "job", chapter: Int = 8, path: URL? = nil) -> RustConversionCoordinator.ChapterCompletionEvent {
            .init(jobId: job, bookTitle: "Book", bookAuthor: "Author", chapterIndex: chapter,
                  chaptersTotal: 2, chaptersCompleted: 1, chapterTitle: "Chapter",
                  filename: "chapter.mp3", audioPath: path ?? audio, textChars: 100)
        }
        func rejection(_ value: RustConversionCoordinator.ChapterCompletionEvent) -> String? {
            chapterDeliveryRejection(value, jobID: "job", start: 8, end: 9, output: output, manager: .default)
        }
        XCTAssertNil(rejection(event()))
        XCTAssertEqual(rejection(event(job: "other")), "job ID mismatch")
        XCTAssertEqual(rejection(event(chapter: 7)), "chapter outside requested range")
        XCTAssertEqual(rejection(event(path: owned.directory.appendingPathComponent("outside.mp3"))), "audio parent outside owned output")
        XCTAssertEqual(rejection(event(path: output.appendingPathComponent("chapter.wav"))), "audio extension is not MP3")
        XCTAssertEqual(rejection(event(path: output.appendingPathComponent("missing.mp3"))), "audio file is not readable")
        let linked = output.appendingPathComponent("linked.mp3")
        let outside = owned.directory.appendingPathComponent("outside.mp3")
        try Data("outside owned output".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertEqual(rejection(event(path: linked)), "audio parent outside owned output")
    }

    func testTemporaryStorageSpecAndReportRoundTrip() throws {
        let owned = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let spec = specification()
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let decoded = try DeviceBenchmarkSpec.decode(json, temporaryRoot: owned.directory)
        XCTAssertEqual(decoded.inputBase, "temporary")
        XCTAssertEqual(decoded.stagedDirectory(temporaryRoot: owned.directory),
                       owned.directory.appendingPathComponent("EpubToMp3/DeviceTestInputs/\(spec.runID)", isDirectory: true))
        let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "applicationSupport",
                                          runID: spec.runID, wholeBook: false, cases: spec.cases)
        XCTAssertThrowsError(try invalid.validate(temporaryRoot: owned.directory))
        let report = DeviceBenchmarkReport(runID: spec.runID, cases: [])
        let destination = owned.directory.appendingPathComponent("DeviceBenchmarkReports/\(spec.runID).json")
        let bytes = try report.save(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    @MainActor
    func testRealCoordinatorUsesIsolatedTemporaryOutputOnInvalidEPUB() async throws {
        let owned = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let manager = BenchmarkFileManager(supportRoot: owned.directory)
        XCTAssertEqual(try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true), owned.directory)
        XCTAssertEqual(try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: false),
                       try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false))
        let input = owned.directory.appendingPathComponent("invalid.epub")
        try Data("Invalid EPUB; no synthesis possible".utf8).write(to: input)
        let job = UUID().uuidString
        let coordinator = RustConversionCoordinator(fileManager: manager)
        do {
            _ = try await coordinator.convert(bookURL: input, jobID: job)
            XCTFail("Invalid EPUB must fail before synthesis")
        } catch {
            let output = owned.directory.appendingPathComponent("EpubToMp3/RustConversions/\(job)")
            XCTAssertTrue(manager.fileExists(atPath: output.appendingPathComponent("conversion.log").path))
            try manager.removeItem(at: output)
            XCTAssertTrue(manager.fileExists(atPath: input.path))
        }
    }

    func testPressureMetricsCountEventsWithoutSummingRetryCounters() {
        let lines = ["tts chunk=1/1 retries=1 result=pressure:Throttle",
                     "tts chunk=1/1 retries=2 result=pressure:Timeout",
                     "tts chunk=1/1 retries=2 result=success"]
        XCTAssertEqual(lines.filter { DeviceBenchmarkReport.Case.result($0)?.hasPrefix("pressure:") == true }.count, 2)
        XCTAssertEqual(lines.filter { DeviceBenchmarkReport.Case.result($0) == "pressure:Throttle" }.count, 1)
    }
}
