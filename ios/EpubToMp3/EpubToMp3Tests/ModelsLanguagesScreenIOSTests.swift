#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// MODELS-LANGUAGE-SUBSCREEN on iOS (UIKit): the language list screen and the row that opens it.
@MainActor
final class ModelsLanguagesScreenIOSTests: XCTestCase {
    private func catalog() throws -> [CatalogLanguage] {
        let json = """
        [{"tag":"ar","model_count":2,"popularity_rank":11},{"tag":"de","model_count":4,"popularity_rank":5},
         {"tag":"en","model_count":9,"popularity_rank":1},{"tag":"es","model_count":6,"popularity_rank":2},
         {"tag":"kk","model_count":1},{"tag":"cy","model_count":1},{"tag":"pt","model_count":3,"popularity_rank":3}]
        """
        return try JSONDecoder().decode([CatalogLanguage].self, from: Data(json.utf8))
    }

    func testLanguageListGroupsSystemPopularAndTheRestAndOpensALanguage() throws {
        var opened: [String] = []
        let controller = ModelsLanguagesScreenController(languages: try catalog(), systemPreferred: ["pt-BR", "en-US"],
                                                         uiLocale: Locale(identifier: "en")) { opened.append($0) }
        controller.loadViewIfNeeded()
        let table = controller.tableView!
        XCTAssertEqual(table.numberOfSections, 3)
        XCTAssertEqual((0..<3).map { controller.tableView(table, titleForHeaderInSection: $0) },
                       [L10n.string("models.languages.system"), L10n.string("models.languages.popular"), L10n.string("models.languages.all")])
        let identifiers = (0..<3).flatMap { section in
            (0..<table.numberOfRows(inSection: section)).map { row in
                controller.tableView(table, cellForRowAt: IndexPath(row: row, section: section)).accessibilityIdentifier
            }
        }
        XCTAssertEqual(identifiers, ["models.languages.row.pt", "models.languages.row.en", "models.languages.row.es",
                                     "models.languages.row.de", "models.languages.row.ar",
                                     "models.languages.row.kk", "models.languages.row.cy"])
        let cell = controller.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, "Portuguese")
        XCTAssertEqual(content.secondaryText, ModelLanguageOrder.modelCountText(3))
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(opened, ["en"])
    }

    func testModelsScreenHasAnAllLanguagesRowAfterTheNarrationSettings() throws {
        let name = "models-languages-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = ModelsScreenController(settings: AppSettings(defaults: defaults),
                                                source: ModelsByLanguageModelTests.FakeSource(),
                                                termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults))
        controller.loadViewIfNeeded()
        let table = controller.tableView!
        let last = table.numberOfRows(inSection: 0) - 1
        let cell = controller.tableView(table, cellForRowAt: IndexPath(row: last, section: 0))
        XCTAssertEqual(cell.accessibilityIdentifier, "models.languages")
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, L10n.string("models.languages.open"))
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
    }
}
#endif
