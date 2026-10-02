import Foundation
import XCTest

final class ConverterFFIAdapterTests: XCTestCase {
    func testMissingArtifactReturnsTypedUnavailableError() {
        let adapter = ConverterFFIAdapter(bundle: Bundle(for: ConverterFFIAdapterTests.self))
        XCTAssertThrowsError(try adapter.openBook(at: URL(fileURLWithPath: "/tmp/book.epub"))) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
    }

    func testMissingArtifactReturnsUnavailableForTtsCatalog() {
        let adapter = ConverterFFIAdapter(bundle: Bundle(for: ConverterFFIAdapterTests.self))
        XCTAssertThrowsError(try adapter.ttsModels()) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.ttsDefaultEngine(language: "pt-BR", platform: "ios")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.installTtsModel(modelID: "kokoro-82m", url: "https://example.invalid/model", sha256: String(repeating: "0", count: 64), root: "/tmp/models")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.removeTtsModel(modelID: "kokoro-82m", root: "/tmp/models")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
    }

    func testInvalidArtifactReturnsTypedUnavailableErrorWithoutRuntimeConversion() throws {
        let bundleURL = try makeBundle(with: Data("not a Mach-O dylib".utf8), name: "converter_ffi")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let adapter = ConverterFFIAdapter(bundle: Bundle(url: bundleURL)!)
        XCTAssertThrowsError(try adapter.openBook(at: URL(fileURLWithPath: "/tmp/book.epub"))) { error in
            guard case .artifactUnavailable? = error as? EmbeddedConverterError else {
                return XCTFail("Expected unavailable artifact, got \(error)")
            }
        }
    }

    func testConverterFFISymbolSignaturesMatchPublishedABI() {
        XCTAssertEqual(MemoryLayout<UnsafePointer<CChar>?>.size, MemoryLayout<UnsafeRawPointer?>.size)
        XCTAssertEqual(MemoryLayout<UnsafeMutableRawPointer?>.size, MemoryLayout<UnsafeMutablePointer<CChar>?>.size)
    }

    private func makeBundle(with dylib: Data, name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try dylib.write(to: root.appendingPathComponent("\(name).dylib"))
        return root
    }
}
