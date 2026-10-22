#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import EpubToMp3

// Shared only by the two existing native observation test suites. Inputs are
// explicit local artifacts, not conversion jobs or whole-book manifests.
struct NativePlaybackBenchmarkInput: Codable, Sendable {
    struct Chapter: Codable, Sendable {
        let sourceIndex: Int
        let path: String
        var sha256: String
    }
    struct Book: Codable, Sendable {
        let name: String
        let sourcePath: String
        let sourceSHA256: String
        var chapterStart: Int
        var chapterEnd: Int
        var chapters: [Chapter]
    }
    let schemaVersion: Int
    let phase: String
    let baselineExecutablePath: String?
    var books: [Book]

    static let environmentKey = "EPUB2MP3_NATIVE_PLAYBACK_BENCHMARK_SPEC"

    static func optIn() throws -> Self {
        guard let json = ProcessInfo.processInfo.environment[environmentKey] else {
            throw XCTSkip("Provide \(environmentKey) with explicit local EPUB/MP3 paths and SHA-256 hashes.")
        }
        let input = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try input.validateScope()
        try input.validateRequestedBooks()
        try input.validateFiles()
        return input
    }

    func validateRequestedBooks() throws {
        let expected = [
            "lotr": "3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e",
            "christie": "55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da",
        ]
        for book in books {
            guard expected[book.name] == book.sourceSHA256.lowercased() else {
                throw Self.invalid("Benchmark requires the literal requested EPUB, not a renamed fixture")
            }
        }
    }

    func validateFiles() throws {
        for book in books {
            guard try Self.hash(book.sourcePath) == book.sourceSHA256.lowercased() else {
                throw Self.invalid("EPUB hash mismatch for \(book.name)")
            }
            for chapter in book.chapters {
                guard try Self.hash(chapter.path) == chapter.sha256.lowercased() else {
                    throw Self.invalid("MP3 hash mismatch at source index \(chapter.sourceIndex)")
                }
            }
        }
    }

    func validateScope() throws {
        guard schemaVersion == 1, ["baseline", "candidate"].contains(phase), books.count == 2,
              Set(books.map(\.name)) == Set(["lotr", "christie"]),
              Set(books.map { $0.sourceSHA256.lowercased() }).count == 2 else { throw Self.invalid("Invalid benchmark scope") }
        var paths = Set<String>()
        for book in books {
            let range = book.name == "lotr" ? 8...9 : 6...7
            guard book.chapterStart == range.lowerBound, book.chapterEnd == range.upperBound,
                  book.chapters.count == 2, book.chapters.map(\.sourceIndex) == Array(range) else {
                throw Self.invalid("Select only LOTR 8-9 and Christie 6-7 in source order")
            }
            for (path, digest, ext) in [(book.sourcePath, book.sourceSHA256, "epub")]
                + book.chapters.map({ ($0.path, $0.sha256, "mp3") }) {
                guard (path as NSString).isAbsolutePath, URL(fileURLWithPath: path).pathExtension.lowercased() == ext,
                      paths.insert(path).inserted, digest.count == 64,
                      digest.allSatisfy({ $0.isHexDigit }) else { throw Self.invalid("Invalid local path or SHA-256") }
            }
        }
    }

    static func hash(_ path: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 65_536), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func invalid(_ message: String) -> NSError {
        NSError(domain: "NativePlaybackBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct NativePlaybackBenchmarkReport: Encodable {
    struct Point: Encodable {
        struct StageTiming: Encodable {
            let name: String
            let elapsedNanoseconds: UInt64
        }

        let book: String
        let event: String
        let elapsedNanoseconds: UInt64
        let residentBytes: UInt64?
        let physicalFootprintBytes: UInt64?
        let memoryStatus: Int32
        let journeys: [LatencyObservation.Journey]
        let stageTimings: [StageTiming]

        static func capture(book: String, event: String, started: UInt64,
                            journeys: [LatencyObservation.Journey] = [],
                            stageTimings: [StageTiming] = []) -> Self {
            let elapsed = stageTimings.first(where: { $0.name == "controls_usable" })?.elapsedNanoseconds
                ?? (DispatchTime.now().uptimeNanoseconds - started)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return Self(book: book, event: event, elapsedNanoseconds: elapsed,
                        residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
                        physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
                        memoryStatus: status, journeys: journeys, stageTimings: stageTimings)
        }
    }
    let input: NativePlaybackBenchmarkInput
    let executablePath: String
    let executableSHA256: String
    let appCodeSHA256: String
    let baselineStatus: String
    let comparison = "unmeasured: requires paired reports from the actual baseline and candidate executables"
    let clock = "client monotonic; audio progress is not acoustic; memory is point sampled, not peak; cold means prepared-reader cache absent, not OS cache flushed"
    var status = "partial"
    var points: [Point] = []

    init(input: NativePlaybackBenchmarkInput) throws {
        self.input = input
        let executable = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath()
        executablePath = executable.path
        executableSHA256 = try NativePlaybackBenchmarkInput.hash(executable.path)
        // Modern Debug builds use an identical launcher across revisions.
        // Identify the loaded app code, not just that launcher stub.
        let debugPayload = executable.deletingLastPathComponent()
            .appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        appCodeSHA256 = try NativePlaybackBenchmarkInput.hash(
            FileManager.default.isReadableFile(atPath: debugPayload.path) ? debugPayload.path : executable.path)
        if let baseline = input.baselineExecutablePath, FileManager.default.isExecutableFile(atPath: baseline) {
            let sameExecutable = URL(fileURLWithPath: baseline).resolvingSymlinksInPath() == executable
            baselineStatus = sameExecutable
                ? (input.phase == "baseline" ? "this_run_is_baseline" : "unmeasured: baseline path is the current candidate")
                : "available_not_executed"
            if input.phase == "baseline", !sameExecutable {
                throw NativePlaybackBenchmarkInput.invalid("Run the supplied baseline executable; do not label the candidate as baseline")
            }
        } else {
            baselineStatus = "unmeasured: baseline executable unavailable"
            if input.phase == "baseline" { throw NativePlaybackBenchmarkInput.invalid("Baseline executable is required") }
        }
    }

    func attachment(_ name: String) throws -> XCTAttachment {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(self), uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

#if os(iOS)
final class AudioSessionEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append("\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)ms:\(event)")
        if events.count > 20 { events.removeFirst() }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.joined(separator: ",")
    }
}
#endif

final class ObservationPrivacyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var interceptedHost = ""
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func configure(host: String) {
        lock.lock()
        defer { lock.unlock() }
        interceptedHost = host
        requests = []
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host == interceptedHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AudioPlayerObservationPrivacyTests: XCTestCase {


    @MainActor
    func benchmarkWait(_ ready: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativePlaybackBenchmarkInput.invalid("Real AVPlayer readiness timed out; do not report a latency success")
    }

}

extension Array where Element == NativePlaybackBenchmarkInput.Chapter {
    func asyncBenchmarkChapters() async throws -> [JobSnapshot.Chapter] {
        var chapters: [JobSnapshot.Chapter] = []
        for (offset, input) in enumerated() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: input.path))
            let playable = try await asset.load(.isPlayable)
            let time = try await asset.load(.duration)
            let duration = time.seconds
            guard playable, duration.isFinite, duration > 2 else {
                throw NativePlaybackBenchmarkInput.invalid("Existing MP3 must be playable and longer than the seek target")
            }
            chapters.append(.init(index: offset, name: "source-\(input.sourceIndex)", status: "completed",
                downloadUrl: URL(fileURLWithPath: input.path).absoluteString, chars: 0, charsProcessed: 0,
                progressRatio: 1, durationSeconds: duration, startedAt: nil, completedAt: nil))
        }
        return chapters
    }
}
#endif
