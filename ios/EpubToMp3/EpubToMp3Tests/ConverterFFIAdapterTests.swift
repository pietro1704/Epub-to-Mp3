import Foundation
import XCTest
@testable import EpubToMp3

final class ConverterFFIAdapterTests: XCTestCase {
    func testMissingOverrideRemainsUnavailableWithAValidBundledCatalog() throws {
        let bundled = ConverterFFIAdapter(bundle: Bundle(for: ConverterFFIAdapterTests.self))
        let catalogData = try bundled.ttsModels()
        let catalogObject = try JSONSerialization.jsonObject(with: catalogData)
        let catalog = try XCTUnwrap(catalogObject as? [[String: Any]])
        XCTAssertTrue(catalog.contains { $0["id"] as? String == "pt_BR-faber-medium" })

        let fixture = try makeArtifactFixture()
        let marker = fixture.root.appendingPathComponent("preserved.txt")
        let original = try Data(contentsOf: marker)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let missing = ConverterFFIAdapter(libraryURL: fixture.libraryURL)
        XCTAssertThrowsError(try missing.ttsModels()) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
    }

    func testMissingArtifactReturnsTypedInvalidErrorBeforeOpeningBook() throws {
        let fixture = try makeArtifactFixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let adapter = ConverterFFIAdapter(libraryURL: fixture.libraryURL)
        XCTAssertThrowsError(try adapter.openBook(at: fixture.root.appendingPathComponent("missing.epub"))) { error in
            guard case .artifactInvalid(let reason)? = error as? EmbeddedConverterError else {
                return XCTFail("Expected typed dylib load failure, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
    }

    func testMissingArtifactReturnsUnavailableForTtsCatalogWithoutFileIO() throws {
        let fixture = try makeArtifactFixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let marker = fixture.root.appendingPathComponent("preserved.txt")
        let markerBytes = try Data(contentsOf: marker)
        let models = fixture.root.appendingPathComponent("models", isDirectory: true)
        let adapter = ConverterFFIAdapter(libraryURL: fixture.libraryURL)
        XCTAssertThrowsError(try adapter.ttsModels()) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.ttsInstalledReadyEngine(language: "en-US", platform: "ios", installedModelIDsJSON: "[]", readyModelIDsJSON: "[]")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.ttsDefaultEngine(language: "pt-BR", platform: "ios")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        // Even a future test failure must not point at an online model or a
        // shared model directory. The unavailable adapter rejects before I/O.
        XCTAssertThrowsError(try adapter.installTtsModel(modelID: "test-unavailable-model", url: fixture.root.appendingPathComponent("missing-model").absoluteString, sha256: String(repeating: "0", count: 64), root: models.path)) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.removeTtsModel(modelID: "test-unavailable-model", root: models.path)) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.ttsModelMetadata(modelID: "test-unavailable-model", root: models.path)) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertThrowsError(try adapter.installTtsModelFromCatalog(modelID: "test-unavailable-model", root: models.path)) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.path))
    }

    func testInvalidArtifactReturnsTypedInvalidErrorWithoutRuntimeConversion() throws {
        let fixture = try makeArtifactFixture(with: Data("not a Mach-O dylib".utf8))
        let artifactBytes = try Data(contentsOf: fixture.libraryURL)
        let adapter = ConverterFFIAdapter(libraryURL: fixture.libraryURL)
        XCTAssertThrowsError(try adapter.openBook(at: fixture.root.appendingPathComponent("missing.epub"))) { error in
            guard case .artifactInvalid(let reason)? = error as? EmbeddedConverterError else {
                return XCTFail("Expected typed dylib load failure, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.libraryURL), artifactBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("missing.epub").path))
    }

    func testConverterFFISymbolSignaturesMatchPublishedABI() {
        XCTAssertEqual(MemoryLayout<UnsafePointer<CChar>?>.size, MemoryLayout<UnsafeRawPointer?>.size)
        XCTAssertEqual(MemoryLayout<UnsafeMutableRawPointer?>.size, MemoryLayout<UnsafeMutablePointer<CChar>?>.size)
    }

    private func makeArtifactFixture(with dylib: Data? = nil) throws -> (root: URL, libraryURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("Preserve this fixture".utf8).write(to: root.appendingPathComponent("preserved.txt"))
        let libraryURL = root.appendingPathComponent("converter_ffi.dylib")
        if let dylib { try dylib.write(to: libraryURL) }
        return (root, libraryURL)
    }
}
