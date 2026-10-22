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
    func testCoordinatorRejectsInvalidOptionsBeforeBookOrOutputAccess() async throws {
        let adapter = try runtimeAdapter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-coordinator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ObservedSupportManager(root: directory)
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: manager,
            outputStore: RustConversionOutputStore(root: directory.appendingPathComponent("outputs"), notificationCenter: NotificationCenter()))
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

    func testExplicitPiperRequiresModelReadinessBeforeBookOrOutputAccess() async throws {
        let adapter = try runtimeAdapter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piper-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ObservedSupportManager(root: directory)
        let coordinator = RustConversionCoordinator(adapter: adapter, fileManager: manager,
            outputStore: RustConversionOutputStore(root: directory.appendingPathComponent("outputs"), notificationCenter: NotificationCenter()))
        for options in [
            ConversionOptions(engine: "piper"),
            ConversionOptions(engine: "piper", modelsRoot: directory.path, modelID: "fixture",
                              modelPath: "model.onnx", modelConfigPath: "model.onnx.json"),
            ConversionOptions(engine: "edge", modelID: "must-not-ignore-model"),
        ] {
            do {
                _ = try await coordinator.convert(bookURL: URL(fileURLWithPath: "/must-not-open-unready-piper.epub"),
                                                  options: options)
                XCTFail("Unready or incompatible model configuration was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("piper"), "Unexpected preflight error: \(error)")
            }
        }
        XCTAssertEqual(manager.supportLookups, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

#if os(iOS) && targetEnvironment(simulator)
    func testActualSimulatorFFIRejectsExplicitPiperWithoutInstalledModelBeforeBookOrOutputAccess() throws {
        let adapter = try runtimeAdapter()
        let input = URL(fileURLWithPath: "/must-not-open-piper-book.epub")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("must-not-create-piper-output-\(UUID().uuidString)")
        let options = ConversionOptions(
            engine: "piper", modelsRoot: "/must-not-read-piper-models",
            modelID: "pt_BR-edresson-low", modelPath: "model.onnx",
            modelConfigPath: "model.onnx.json"
        )

        XCTAssertThrowsError(try adapter.convertBook(
            at: input, outputDirectory: output, jobID: output.lastPathComponent,
            chapterStart: 0, chapterEnd: 0, options: options
        )) { error in
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("piper model"),
                "Unexpected missing-model result: \(error)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
#endif

    func testExplicitOptionsNeverFallBackToAnUnavailableABI() throws {
        let adapter = ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: "/unused-converter-library.dylib"))
        XCTAssertThrowsError(try adapter.convertBook(at: URL(fileURLWithPath: "/must-not-open-book.epub"),
                                                   outputDirectory: URL(fileURLWithPath: "/must-not-create-output"),
                                                   jobID: "must-not-create-output", options: ConversionOptions(engine: "piper"))) {
            XCTAssertEqual($0 as? EmbeddedConverterError, .optionsABIUnavailable)
        }
    }

    func testActualSwiftRustOptionsRejectUnsupportedValuesBeforeOutputWork() throws {
        let adapter = try runtimeAdapter()
        let bookURL = try EpubFixture.createWithChapter()
        defer { try? FileManager.default.removeItem(at: bookURL) }
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
