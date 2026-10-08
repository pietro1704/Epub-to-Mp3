import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ConversionOptionsInteropTests: XCTestCase {
    func testScopedManifestRequiresExactOrderedChapterIdentities() throws {
        func result(_ indices: [Int?], jobID: String = "selected-job") throws -> RustConversionCoordinator.Result {
            let chapters: [[String: Any]] = indices.enumerated().map { offset, index in
                var chapter: [String: Any] = ["filename": "chapter-\(offset).mp3", "textChars": 42]
                if let index { chapter["sourceIndex"] = index }
                return chapter
            }
            let data = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": jobID, "title": "Fixture", "author": "Author", "chapters": chapters,
            ]])
            return .init(jobID: "selected-job", manifestJSON: data,
                         outputDirectory: URL(fileURLWithPath: "/unused-selection-output"))
        }
        try result([8, 9]).validateSelectedChapters(8...9)
        try result([8]).validateSelectedChapters(8...8)
        for indices: [Int?] in [[0, 1], [8, 8], [9, 8], [8], [8, 9, 10], [nil, nil], [8, nil]] {
            XCTAssertThrowsError(try result(indices).validateSelectedChapters(8...9), "Accepted \(indices)")
        }
        XCTAssertThrowsError(try result([8, 9], jobID: "different-job").validateSelectedChapters(8...9))
    }

    private final class ObservedSupportManager: FileManager, @unchecked Sendable {
        let root: URL
        var supportLookups = 0
        init(root: URL) { self.root = root; super.init() }
        override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            supportLookups += 1
            return root
        }
    }

    func testCoordinatorRejectsInvalidOptionsBeforeBookOrOutputAccess() async throws {
        guard let path = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_LIBRARY"] else {
            throw XCTSkip("Run apple:foundation:ffi:test for the real host dylib boundary.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-coordinator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ObservedSupportManager(root: directory)
        let coordinator = RustConversionCoordinator(adapter: ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: path)), fileManager: manager)
        do {
            _ = try await coordinator.convert(bookURL: URL(fileURLWithPath: "/must-not-open-book.epub"),
                                              options: ConversionOptions(engine: "coqui"))
            XCTFail("Unsupported provider unexpectedly accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsupported conversion engine"))
        }
        XCTAssertEqual(manager.supportLookups, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOptionsEncodeExactRustKeysAndLiteralVoiceLanguage() throws {
        let options = ConversionOptions(engine: "piper", voice: "speaker-0", language: "pt-BR",
                                        clearCache: true, forceReprocess: true, maxPerformance: true)
        let json = try options.encodedJSON()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["schema_version", "engine", "voice", "language", "clear_cache", "force_reprocess", "max_performance"]))
        XCTAssertEqual(fields["schema_version"] as? Int, 1)
        XCTAssertEqual(fields["voice"] as? String, "speaker-0")
        XCTAssertEqual(fields["language"] as? String, "pt-BR")
        XCTAssertEqual(fields["clear_cache"] as? Bool, true)
        XCTAssertEqual(fields["force_reprocess"] as? Bool, true)
        XCTAssertEqual(fields["max_performance"] as? Bool, true)
    }

    func testExplicitOptionsNeverFallBackToAnUnavailableABI() throws {
        let adapter = ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: "/unused-converter-library.dylib"))
        XCTAssertThrowsError(try adapter.convertBook(at: URL(fileURLWithPath: "/must-not-open-book.epub"),
                                                   outputDirectory: URL(fileURLWithPath: "/must-not-create-output"),
                                                   jobID: "must-not-create-output", options: ConversionOptions(engine: "piper"))) {
            XCTAssertEqual($0 as? EmbeddedConverterError, .optionsABIUnavailable)
        }
    }

    func testActualSwiftRustOptionsRejectUnsupportedValuesBeforeOutputWork() throws {
        guard let path = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_LIBRARY"],
              let fixture = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_FIXTURE"] else {
            throw XCTSkip("Run apple:foundation:ffi:test for the real host dylib boundary.")
        }
        let adapter = ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: path))
        let bookURL = URL(fileURLWithPath: fixture)
        _ = try adapter.openBook(at: bookURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-options-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked-output")
        let original = Data("Original output fixture".utf8)
        try original.write(to: blocked)
        for (options, expected) in [
            (ConversionOptions(engine: "coqui"), "unsupported conversion engine"),
            (ConversionOptions(language: "\n"), "language"),
        ] {
            XCTAssertThrowsError(try adapter.convertBook(at: bookURL, outputDirectory: blocked, jobID: "blocked-output",
                                                       chapterStart: 0, chapterEnd: 0, options: options)) {
                XCTAssertTrue($0.localizedDescription.contains(expected), "Unexpected boundary error: \($0)")
            }
        }
        for options: ConversionOptions? in [
            nil,
            ConversionOptions(engine: "edge", voice: "pt-BR-FranciscaNeural", language: "pt-BR"),
            ConversionOptions(clearCache: true),
            ConversionOptions(forceReprocess: true),
            ConversionOptions(maxPerformance: true),
            ConversionOptions(clearCache: true, forceReprocess: true, maxPerformance: true),
        ] {
            XCTAssertThrowsError(try adapter.convertBook(at: bookURL, outputDirectory: blocked, jobID: "blocked-output",
                                                       chapterStart: 0, chapterEnd: 0, options: options)) {
                XCTAssertTrue($0.localizedDescription.contains("create output directory"), "Valid options did not reach the output boundary: \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: blocked), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["blocked-output"])
    }
}
