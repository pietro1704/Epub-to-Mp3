import Foundation
import XCTest
@testable import EpubToMp3

final class BundledConverterFFISmokeTests: XCTestCase {
    func testAppBundledRustLibraryLoadsAndReturnsCatalog() throws {
        #if os(iOS)
        let library = Bundle.main.bundleURL.appendingPathComponent("Frameworks/libconverter_ffi.dylib")
        #else
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL)
            .appendingPathComponent("libconverter_ffi.dylib")
        #endif
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        // Explicit bundle URL prevents test overrides from hiding packaging failures.
        let adapter = ConverterFFIAdapter(libraryURL: library)
        let catalog = try adapter.ttsModels()
        XCTAssertFalse(catalog.isEmpty)
        _ = try JSONSerialization.jsonObject(with: catalog)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-model-catalog-v3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = SpeechModelLibraryTarget(
            language: "pt-BR",
            platform: {
                #if os(iOS)
                "ios"
                #else
                "macos"
                #endif
            }(),
            androidAPI: 0,
            architecture: "test",
            osVersion: "test",
            modelsRoot: root
        )
        let snapshot = try adapter.speechModelSnapshot(target: target)
        XCTAssertEqual(snapshot.schemaVersion, 3)
        let faber = try XCTUnwrap(snapshot.entries.first {
            $0.identity.modelID == "pt_BR-faber-medium"
        })
        XCTAssertEqual(faber.presentation.modelName, "Faber")
        XCTAssertEqual(faber.installation.state, .missing)
        XCTAssertFalse(snapshot.entries.contains {
            $0.identity.modelID == "piper-default" && $0.distribution.installable
        })
    }
}
