import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import EpubToMp3

extension DeviceConversionBenchmarkTests {
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
        let coordinator = RustConversionCoordinator(fileManager: manager,
            outputStore: RustConversionOutputStore(root: owned.directory.appendingPathComponent("EpubToMp3/RustConversions")))
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
}
