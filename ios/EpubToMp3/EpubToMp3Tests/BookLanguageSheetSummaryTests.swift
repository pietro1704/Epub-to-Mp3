import XCTest
@testable import EpubToMp3

/// A3: the book language sheet says what was detected and lists languages in the Models order.
final class BookLanguageSheetSummaryTests: XCTestCase {
    private let english = Locale(identifier: "en")

    private func analysis(declared: String?, profile: String?) throws -> BookLanguageAnalysis {
        let declaredJSON = declared.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"declared":\(declaredJSON),"confirmed":null,"languages":[],"samples_examined":1,"inconclusive_samples":0\
        \(profile.map { ",\"profile\":\($0)" } ?? "")}
        """
        return try JSONDecoder().decode(BookLanguageAnalysis.self, from: Data(json.utf8))
    }

    private let portuguese = """
    {"class":"monolingual","primary":"pt","incidental":["fr","la"],
     "languages":[{"language":"pt","chars":980,"fraction":0.98,"longest_section_chars":980}]}
    """

    func testTheSummaryNamesTheShareTheQuotationsAndTheDeclaredConflict() throws {
        let summary = try XCTUnwrap(BookLanguageSheetSummary(
            analysis: analysis(declared: "en-US", profile: portuguese), uiLocale: english))
        XCTAssertEqual(summary.detected,
                       L10n.string("language.detected", "Portuguese 98%") + " " + L10n.string("language.quoted", "French, Latin"))
        XCTAssertEqual(summary.conflict, L10n.string("language.conflict", "English", "Portuguese"))
    }

    func testAMatchingOrEmptyDeclarationIsNoConflict() throws {
        for declared in ["pt-BR", "und", nil] {
            let summary = BookLanguageSheetSummary(analysis: try analysis(declared: declared, profile: portuguese),
                                                   uiLocale: english)
            XCTAssertNil(try XCTUnwrap(summary).conflict, declared ?? "nil")
        }
    }

    func testWithoutAProfileThereIsNothingToSay() throws {
        XCTAssertNil(BookLanguageSheetSummary(analysis: try analysis(declared: "en", profile: nil), uiLocale: english))
    }

    func testTheListFollowsTheModelsOrderAndKeepsVariantsTogether() throws {
        let catalog = try JSONDecoder().decode([CatalogLanguage].self, from: Data("""
        [{"tag":"en","model_count":9,"popularity_rank":1},{"tag":"es","model_count":6,"popularity_rank":2}]
        """.utf8))
        let ordered = BookLanguageSheetSummary.ordered(["cy", "de", "en", "en-US", "es", "pt", "pt-BR"], catalog: catalog,
                                                       systemPreferred: ["pt-BR"], uiLocale: english)
        XCTAssertEqual(ordered, ["pt", "pt-BR", "en", "en-US", "es", "de", "cy"])
    }
}
