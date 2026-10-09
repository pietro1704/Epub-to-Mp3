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
    }
}
