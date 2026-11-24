import XCTest
@testable import EpubToMp3

/// MODELS-LANGUAGE-SUBSCREEN: the order of the languages on the Models language screen
/// (CONTEXT.md, "Models screen language order"): system languages, then `popularity_rank`, then alphabetical.
final class ModelLanguageOrderTests: XCTestCase {
    /// A fixed `converter_tts_catalog_languages_json_v1` payload: `popularity_rank` is 1-based and absent when the
    /// language is outside the shared list.
    private let catalogJSON = """
    {"schema_version":1,"languages":[
      {"tag":"ar","model_count":2,"popularity_rank":11},
      {"tag":"bg","model_count":1,"popularity_rank":29},
      {"tag":"cy","model_count":1},
      {"tag":"de","model_count":4,"popularity_rank":5},
      {"tag":"en","model_count":9,"popularity_rank":1},
      {"tag":"es","model_count":6,"popularity_rank":2},
      {"tag":"kk","model_count":1},
      {"tag":"pt","model_count":3,"popularity_rank":3}
    ]}
    """

    private func catalog() throws -> [CatalogLanguage] {
        struct Envelope: Decodable { let languages: [CatalogLanguage] }
        return try JSONDecoder().decode(Envelope.self, from: Data(catalogJSON.utf8)).languages
    }

    func testPopularityRankIsDecodedAndOptional() throws {
        let languages = try catalog()
        XCTAssertEqual(languages.first { $0.tag == "en" }?.popularityRank, 1)
        XCTAssertNil(languages.first { $0.tag == "cy" }?.popularityRank)
    }

    func testSystemLanguagesComeFirstInTheSystemsOwnOrder() throws {
        let order = ModelLanguageOrder.sections(languages: try catalog(),
                                                systemPreferred: ["pt-BR", "en-US", "pt-PT", "xx-YY"],
                                                uiLocale: Locale(identifier: "en"))
        XCTAssertEqual(order.system, ["pt", "en"], "Base tags, system order, no duplicates, unknown languages dropped")
    }

    func testPopularLanguagesFollowByRankWithoutRepeatingSystemOnes() throws {
        let order = ModelLanguageOrder.sections(languages: try catalog(), systemPreferred: ["pt-BR"],
                                                uiLocale: Locale(identifier: "en"))
        XCTAssertEqual(order.system, ["pt"])
        XCTAssertEqual(order.popular, ["en", "es", "de", "ar", "bg"])
    }

    func testTheRestIsAlphabeticalInTheUILanguage() throws {
        let english = ModelLanguageOrder.sections(languages: try catalog(), systemPreferred: [],
                                                  uiLocale: Locale(identifier: "en"))
        XCTAssertEqual(english.others, ["kk", "cy"], "Kazakh, Welsh")
        let languages = [CatalogLanguage(tag: "kk", modelCount: 1), CatalogLanguage(tag: "cy", modelCount: 1),
                         CatalogLanguage(tag: "af", modelCount: 1)]
        let portuguese = ModelLanguageOrder.sections(languages: languages, systemPreferred: [],
                                                     uiLocale: Locale(identifier: "pt-BR"))
        XCTAssertEqual(portuguese.others, ["af", "kk", "cy"], "africâner, cazaque, galês")
    }

    func testEveryCatalogLanguageAppearsExactlyOnce() throws {
        let languages = try catalog()
        for system in [[], ["en"], ["kk-KZ", "cy", "de-AT", "en-GB", "en-US"]] {
            let order = ModelLanguageOrder.sections(languages: languages, systemPreferred: system,
                                                    uiLocale: Locale(identifier: "es"))
            let all = order.system + order.popular + order.others
            XCTAssertEqual(all.sorted(), languages.map(\.tag).sorted(), "system \(system)")
            XCTAssertEqual(Set(all).count, all.count)
        }
    }

    func testABaseTagIgnoresRegionScriptAndSeparators() {
        XCTAssertEqual(ModelLanguageOrder.baseTag("pt-BR"), "pt")
        XCTAssertEqual(ModelLanguageOrder.baseTag("zh_Hans_CN"), "zh")
        XCTAssertEqual(ModelLanguageOrder.baseTag("EN"), "en")
        XCTAssertEqual(ModelLanguageOrder.baseTag("nb"), "nb")
    }
}
