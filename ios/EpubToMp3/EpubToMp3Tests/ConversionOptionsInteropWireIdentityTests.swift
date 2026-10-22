import Foundation
import XCTest
import AVFoundation
import ImageIO
#if os(macOS) && !APP_FOUNDATION_HOST_TESTS
import AppKit
#endif
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

extension ConversionOptionsInteropTests {
    func testFixtureCoverFullyDecodesAsPNG() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(EpubFixture.coverPNG as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(CGImageSourceGetStatus(source), .statusComplete)
    }

    func testChapterFixtureHasReadableSpineAndCoverInActualRustParser() throws {
        let source = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: source) }
        let metadata = try runtimeAdapter().openBook(at: source).metadataJSON
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let chapters = try XCTUnwrap(fields["chapters"] as? [[String: Any]])
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(fields["title"] as? String, EpubFixture.title)
        // Rust validates the referenced cover while opening, unlike a metadata-
        // only fixture that can hide an empty spine or unresolved cover path.
    }

    func testExplicitModelConfigurationPreservesLiteralScopedPaths() throws {
        let options = ConversionOptions(engine: "piper", modelsRoot: "/app/tts-models",
                                        modelID: "pt_BR-edresson-low", modelPath: "model.onnx",
                                        modelConfigPath: "model.onnx.json",
                                        espeakDataDirectory: "/app/Resources")
        let data = Data(try options.encodedJSON().utf8)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["models_root"] as? String, "/app/tts-models")
        XCTAssertEqual(fields["model_id"] as? String, "pt_BR-edresson-low")
        XCTAssertEqual(fields["model_path"] as? String, "model.onnx")
        XCTAssertEqual(fields["model_config_path"] as? String, "model.onnx.json")
        XCTAssertEqual(fields["espeak_data_directory"] as? String, "/app/Resources")
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: data), options)
    }

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
}
