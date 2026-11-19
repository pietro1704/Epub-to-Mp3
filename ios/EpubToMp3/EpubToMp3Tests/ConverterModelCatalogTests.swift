import XCTest
@testable import EpubToMp3

final class ConverterModelCatalogTests: XCTestCase {
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
