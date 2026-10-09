import Foundation
import CryptoKit

public struct WorkflowError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct Options {
    public enum Action: String { case preflight, test, benchmark, status }
    public var action: Action
    public var device: String
    public var reportDirectory: URL
    public var state: URL
    public var skipBuild: Bool
    public var timeout: Int = 900
    public var wholeBook = false
    public var preview = false
    public var rawCases: [[String]] = []

    public init(arguments: [String], root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let first = arguments.first, let action = Action(rawValue: first) else {
            throw WorkflowError("Usage: device-workflow preflight|test|benchmark|status [options]")
        }
        self.action = action
        device = environment["IOS_DEVICE_ID"] ?? "44B2CFBD-2193-5086-8E8D-BF7A2876C321"
        reportDirectory = root.appendingPathComponent(".reports/device")
        state = reportDirectory.appendingPathComponent("latest.json")
        skipBuild = environment["IOS_SKIP_BUILD"] == "1"
        var explicitState = false
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw WorkflowError("Missing option value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--device": device = try value()
            case "--report-dir": reportDirectory = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--state": state = URL(fileURLWithPath: try value()); explicitState = true
            case "--skip-build": skipBuild = true
            case "--timeout":
                guard let number = Int(try value()), number > 0, number <= Int(Int32.max) - 120 else {
                    throw WorkflowError("Timeout must be a positive bounded integer.")
                }
                timeout = number
            case "--whole-book": wholeBook = true
            case "--preview": preview = true
            case "--case": rawCases.append([try value(), try value(), try value()])
            default: throw WorkflowError("Unknown option: \(option)")
            }
            index += 1
        }
        if !explicitState { state = reportDirectory.appendingPathComponent("latest.json") }
        guard !device.isEmpty else { throw WorkflowError("Device identifier is empty.") }
        guard action == .benchmark || (!preview && !wholeBook && rawCases.isEmpty) else {
            throw WorkflowError("Scope options require benchmark.")
        }
        guard !explicitState || action == .status else { throw WorkflowError("--state requires status.") }
    }
}

public struct BenchmarkCase {
    public static let inputBase = "temporary"
    public static func stagedPath(runID: String) -> String {
        "tmp/EpubToMp3/DeviceTestInputs/\(runID)"
    }
    public static func reportPath(runID: String) -> String {
        "tmp/DeviceBenchmarkReports/\(runID).json"
    }
    public let source: URL
    public let digest: String
    public let start: Int
    public let end: Int
    public let bookPath: String
    public let jobID: String
    public var specification: [String: Any] {
        ["bookPath": bookPath, "chapterStart": start, "chapterEnd": end, "jobID": jobID]
    }
    public var report: [String: Any] {
        specification.merging([
            "sourcePath": source.path, "sourceSHA256": digest,
            "chaptersRequested": start == -1 ? "all" as Any : (end - start + 1) as Any,
        ]) { _, new in new }
    }

    public static func validate(_ raw: [[String]], wholeBook: Bool, runID: String) throws -> [BenchmarkCase] {
        guard UUID(uuidString: runID) != nil, !raw.isEmpty else {
            throw WorkflowError("Specify at least one --case BOOK START END and a valid run UUID.")
        }
        var hashes = Set<String>()
        return try raw.enumerated().map { index, fields in
            guard fields.count == 3, let start = Int(fields[1]), let end = Int(fields[2]) else {
                throw WorkflowError("Each case requires BOOK and integer START END.")
            }
            let full = start == -1 && end == -1
            guard (full && wholeBook) || (start >= 0 && end >= start && end <= Int(Int32.max) && end - start <= 1) else {
                throw WorkflowError("Select one or two zero-based inclusive chapters; whole-book requires --whole-book and -1 -1.")
            }
            let source = URL(fileURLWithPath: (fields[0] as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, source.pathExtension.lowercased() == "epub",
                  FileManager.default.isReadableFile(atPath: source.path) else {
                throw WorkflowError("Not a readable EPUB file: \(source.path)")
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard hashes.insert(digest).inserted else {
                throw WorkflowError("Duplicate book content; copies and hard links share the per-book limit.")
            }
            return BenchmarkCase(source: source, digest: digest, start: start, end: end,
                                 bookPath: "EpubToMp3/DeviceTestInputs/\(runID)/book-\(index).epub", jobID: UUID().uuidString)
        }
    }
}
