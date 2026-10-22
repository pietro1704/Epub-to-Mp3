import Darwin
import XCTest
@testable import EpubToMp3

final class ConverterModelCatalogTests: XCTestCase {
    func testCatalogReadsOwnedNativeJSONWithoutChangingModelIdentity() throws {
        let catalog = ConverterModelCatalog(
            available: true,
            freeString: { free($0) },
            modelsJSON: { strdup("{\"models\":[{\"id\":\"literal-model-id\"}]}") }
        )
        let json = try catalog.ttsModels()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: [[String: String]]])
        XCTAssertEqual(payload["models"]?.first?["id"], "literal-model-id")
    }

    func testUnavailableCatalogAndMissingMutationSymbolsFailClosed() {
        let unavailable = ConverterModelCatalog()
        XCTAssertThrowsError(try unavailable.ttsModels()) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        let readOnly = ConverterModelCatalog(available: true)
        XCTAssertThrowsError(try readOnly.removeTtsModel(modelID: "literal-model-id", root: "/unchanged")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
    }
}
