import Darwin
import XCTest
@testable import EpubToMp3

final class ConverterModelCatalogTests: XCTestCase {
    func testCatalogReadsOwnedNativeJSONWithoutChangingModelIdentity() throws {
        let catalog = ConverterModelCatalog(
            available: true,
            freeString: { free($0) },
            catalogJSONV3: { _, _, _, _, _, _ in strdup(TtsCatalogFixture.json) }
        )
        let result = try catalog.ttsCatalog()
        XCTAssertEqual(result.models.first?.id, "model-a")
        XCTAssertEqual(result.models.first?.revision, "sha-a")
    }

    func testUnavailableCatalogAndMissingMutationSymbolsFailClosed() {
        let unavailable = ConverterModelCatalog()
        XCTAssertThrowsError(try unavailable.ttsCatalog()) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
        let readOnly = ConverterModelCatalog(available: true)
        XCTAssertThrowsError(try readOnly.removeTtsModel(modelID: "literal-model-id", root: "/unchanged")) { error in
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }
    }
}
