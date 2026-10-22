#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import EpubToMp3

extension AudioPlayerObservationPrivacyTests {
    func testBenchmarkInputScopeAndHashesWithoutMeasuringPerformance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let books = try ["lotr", "christie"].map { name -> NativePlaybackBenchmarkInput.Book in
            let source = root.appendingPathComponent("\(name).epub")
            try Data(name.utf8).write(to: source)
            let range = name == "lotr" ? 8...9 : 6...7
            let chapters = try range.map { index -> NativePlaybackBenchmarkInput.Chapter in
                let path = root.appendingPathComponent("\(name)-\(index).mp3")
                try Data("\(name)-\(index)".utf8).write(to: path)
                return .init(sourceIndex: index, path: path.path, sha256: try NativePlaybackBenchmarkInput.hash(path.path))
            }
            return .init(name: name, sourcePath: source.path, sourceSHA256: try NativePlaybackBenchmarkInput.hash(source.path),
                         chapterStart: range.lowerBound, chapterEnd: range.upperBound, chapters: chapters)
        }
        var input = NativePlaybackBenchmarkInput(schemaVersion: 1, phase: "candidate", baselineExecutablePath: nil, books: books)
        XCTAssertThrowsError(try input.validateRequestedBooks(), "Named synthetic fixtures must not impersonate requested books")
        try input.validateScope()
        let roundTrip = try JSONDecoder().decode(NativePlaybackBenchmarkInput.self, from: JSONEncoder().encode(input))
        let report = try NativePlaybackBenchmarkReport(input: roundTrip)
        let executable = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath()
        let payload = executable.deletingLastPathComponent()
            .appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        let code = FileManager.default.isReadableFile(atPath: payload.path) ? payload : executable
        XCTAssertEqual(report.appCodeSHA256, try NativePlaybackBenchmarkInput.hash(code.path))
        try roundTrip.validateScope()
        try roundTrip.validateFiles()
        XCTAssertEqual(try NativePlaybackBenchmarkInput.hash(books[0].chapters[0].path), books[0].chapters[0].sha256)
        try Data("changed fixture bytes".utf8).write(to: URL(fileURLWithPath: books[0].chapters[0].path))
        XCTAssertThrowsError(try roundTrip.validateFiles())
        input.books[0].chapterEnd = 10
        XCTAssertThrowsError(try input.validateScope())
        input.books[0] = books[0]
        input.books[0].chapters.append(books[0].chapters[0])
        XCTAssertThrowsError(try input.validateScope())
    }
}
#endif
