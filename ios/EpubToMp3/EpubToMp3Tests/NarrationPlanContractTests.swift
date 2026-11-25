import XCTest
@testable import EpubToMp3

/// A1: the Apple client asks the real Rust library for the narration plan of a book.
final class NarrationPlanContractTests: XCTestCase {
    /// Shaped like `converter_book_language_json_v1`: a Portuguese book with a French quotation.
    private let bookLanguageJSON = Data("""
        {"schema_version":1,"declared":"pt","confirmed":"fr-FR","languages":["fr-FR","pt-BR"],"samples_examined":32,
         "inconclusive_samples":0,"detector":"whatlang-0.18/book-consensus-v1",
         "profile":{"version":2,"detector":"whatlang-0.18/book-profile-v1","class":"monolingual","primary":"pt-BR",
           "languages":[{"language":"pt-BR","chars":900,"fraction":1.0,"longest_section_chars":900,"role":"main"}],
           "incidental":["fr-FR"],"total_chars":900,"undetermined_chars":0}}
        """.utf8)

    private func inputs() -> NarrationPlanInputs {
        var voices = LanguageModelResolutionRequest(bookLanguage: "", platform: LanguageModelResolutionRequest.currentPlatform)
        voices.installedModelIDs = ["pt_BR-faber-medium", "pt_BR-cadu-medium"]
        voices.primary = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)
        return NarrationPlanInputs(voices: voices)
    }

    func testTheRequestForwardsRustsAnalysisAndProfileUntouched() throws {
        let body = try inputs().requestBody(bookLanguageJSON: bookLanguageJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["declared"] as? String, "pt")
        let profile = try XCTUnwrap(object["profile"] as? [String: Any])
        XCTAssertEqual(profile["total_chars"] as? Int, 900, "A field Swift does not model still reaches Rust")
        let analysis = try XCTUnwrap(object["analysis"] as? [String: Any])
        XCTAssertEqual(analysis["detector"] as? String, "whatlang-0.18/book-consensus-v1")
        XCTAssertNil(analysis["profile"])
        XCTAssertNil(object["book_language"], "The plan decides the language")
    }

    func testRustPlansThePortugueseVoiceForABookWithAFrenchQuotation() throws {
        let plan = try ConverterFFIAdapter().narrationPlan(bookLanguageJSON: bookLanguageJSON, inputs: inputs())
        XCTAssertEqual(plan.decision.language, "pt-BR")
        XCTAssertEqual(plan.decision.source, "profile")
        XCTAssertEqual(plan.main?.source, .primary)
        XCTAssertFalse(plan.mainMissing)
        XCTAssertFalse(plan.needsLanguageQuestion)
        XCTAssertTrue(plan.notifyMissing.isEmpty)
    }

    func testTheListenersBookVoiceReachesRust() throws {
        var request = inputs()
        request.bookVoice = TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil)
        let plan = try ConverterFFIAdapter().narrationPlan(bookLanguageJSON: bookLanguageJSON, inputs: request)
        XCTAssertEqual(plan.main?.source, .bookVoice)
        XCTAssertEqual(plan.main?.selection?.modelID, "pt_BR-cadu-medium")
    }
}
