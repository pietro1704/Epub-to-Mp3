import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class ManualConversionDeliveryTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func snapshot(_ files: [(title: String, path: String)]) throws -> JobSnapshot {
        let chapters: [[String: Any]] = files.enumerated().map { index, file in
            ["index": index, "name": file.title, "status": "completed", "downloadUrl": file.path]
        }
        let object: [String: Any] = ["jobId": "delivery", "state": "finished", "bookTitle": "Hamlet",
                                     "bookAuthor": "Shakespeare", "chapterProgress": chapters]
        return try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func audiobook() throws -> ManualConversionDelivery.Audiobook {
        let source = try directory("delivery-audio")
        let chapters = try ["Um", "Dois"].map { title -> (title: String, path: String) in
            let file = source.appendingPathComponent("\(title).mp3")
            try CompletedMP3Fixture.data(frames: 80).write(to: file)
            return (title, file.path)
        }
        return try XCTUnwrap(ManualConversionDelivery.audiobook(
            from: snapshot(chapters), libraryBook: nil, source: URL(fileURLWithPath: "/fixture/hamlet.epub")))
    }

    func testAddToLibraryImportsTheSourceAndLinksTheJob() async throws {
        let suite = "ManualDelivery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let source = try EpubFixture.createWithChapters(["First chapter"])
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: try directory("delivery-library"))
        XCTAssertTrue(library.books.isEmpty)

        let book = try await ManualConversionDelivery.addToLibrary(source: source, jobID: "job-7", library: library)

        XCTAssertEqual(book.id, try BookContentIdentity.hash(of: source))
        XCTAssertEqual(library.books.map(\.id), [book.id])
        XCTAssertEqual(library.books.first?.lastJobId, "job-7", "The reader must follow the converted audio")
    }

    func testAudiobookKeepsContentsOrderAndOnlyMP3Chapters() throws {
        let book = try XCTUnwrap(ManualConversionDelivery.audiobook(
            from: snapshot([("Um", "/a/1.mp3"), ("Nota", "/a/2.wav"), ("Dois", "/a/3.MP3")]),
            libraryBook: nil, source: URL(fileURLWithPath: "/fixture/hamlet.epub")))
        XCTAssertEqual(book.title, "Hamlet")
        XCTAssertEqual(book.author, "Shakespeare")
        XCTAssertEqual(book.chapters.map(\.title), ["Um", "Dois"])
        XCTAssertNil(ManualConversionDelivery.audiobook(
            from: try snapshot([("Um", "/a/1.wav")]), libraryBook: nil,
            source: URL(fileURLWithPath: "/fixture/hamlet.epub")))
    }

    func testMP3ExportNamesChaptersInContentsOrderAndNeverOverwrites() async throws {
        let book = try audiobook()
        let out = try directory("delivery-mp3")

        let first = try await ManualConversionDelivery.export(book, layout: .perChapter, format: .mp3, to: out)
        let second = try await ManualConversionDelivery.export(book, layout: .perChapter, format: .mp3, to: out)

        XCTAssertEqual(first.map(\.lastPathComponent), ["01 - Um.mp3", "02 - Dois.mp3"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["01 - Um (2).mp3", "02 - Dois (2).mp3"])
    }

    func testM4AExportWritesPlayableFilesForBothLayoutsAndNeverOverwrites() async throws {
        let book = try audiobook()
        let out = try directory("delivery-m4a")
        let occupied = out.appendingPathComponent("Hamlet.m4a")
        try Data("keep".utf8).write(to: occupied)

        let chapters = try await ManualConversionDelivery.export(book, layout: .perChapter, format: .m4a, to: out)
        let single = try await ManualConversionDelivery.export(book, layout: .single, format: .m4a, to: out)

        XCTAssertEqual(chapters.map(\.lastPathComponent), ["01 - Um.m4a", "02 - Dois.m4a"])
        XCTAssertEqual(single.map(\.lastPathComponent), ["Hamlet (2).m4a"])
        XCTAssertEqual(try Data(contentsOf: occupied), Data("keep".utf8))
        for file in chapters + single {
            let audio = try AVAudioFile(forReading: file)
            XCTAssertGreaterThan(audio.length, 0, file.lastPathComponent)
            XCTAssertEqual(audio.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".mp3") }, "Intermediate MP3 files must not reach the folder")
    }
}
