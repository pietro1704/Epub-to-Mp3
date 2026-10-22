import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import EpubToMp3

struct DeviceBenchmarkSpec: Codable {
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

struct BenchmarkFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BenchmarkFailure(message) }
}

// Redirect only the benchmark coordinator's existing FileManager dependency.
final class BenchmarkFileManager: FileManager, @unchecked Sendable {
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

func validateBenchmarkOutputParent(_ output: URL) throws {
    let parent = output.deletingLastPathComponent().standardizedFileURL
    // URL equality also compares directory hints; resolving a missing directory
    // drops its trailing slash. Compare filesystem paths while rejecting symlinks.
    try require(parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path,
                "Unsafe output directory.")
}

struct BenchmarkInputCopies {
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

struct BenchmarkFootprintSample: Encodable {
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

struct BenchmarkConversionMeasurements: Encodable {
    let semantics = "Client monotonic callback delivery of a published chapter MP3, not acoustic playback; process footprint point samples, not peak. Missing optional values are unmeasured."
    var beforeSynthesis: BenchmarkFootprintSample?
    var afterSynthesis: BenchmarkFootprintSample?
    var firstPlayableChapterDeliverySeconds: Double?
    var firstPlayableChapterIndex: Int?
    var rejectedChapterDeliveries: [String] = []
}

func chapterDeliveryRejection(
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
final class BenchmarkDeliveryRecorder {
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

struct DeviceBenchmarkReport: Encodable {
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

    let validationRoot = URL(fileURLWithPath: "/device-benchmark-unit-tests", isDirectory: true)

    func specification(start: Int = 4, end: Int = 5, wholeBook: Bool = false) -> DeviceBenchmarkSpec {
        let run = UUID().uuidString
        return .init(schemaVersion: 2, inputBase: "temporary", runID: run, wholeBook: wholeBook, cases: [
            .init(bookPath: "EpubToMp3/DeviceTestInputs/\(run)/book-0.epub",
                  chapterStart: start, chapterEnd: end, jobID: UUID().uuidString)
        ])
    }



















}
