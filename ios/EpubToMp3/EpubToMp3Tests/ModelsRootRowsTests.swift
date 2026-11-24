import XCTest
@testable import EpubToMp3

final class ModelsRootRowsTests: XCTestCase {
    private let faber = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)

    private func resolution(_ language: String, _ status: LanguageModelResolution.Status,
                            selection: TtsSelection? = nil) throws -> LanguageModelResolution {
        let selected = selection.map { _ in "{}" }
        _ = selected
        let json = """
            {"book_language":"\(language)","status":"\(status.rawValue)","reasons":[]\(status == .missingModel
                ? ",\"missing\":{\"language\":\"\(language)\",\"suggested\":[]}" : "")}
            """
        return try JSONDecoder().decode(LanguageModelResolution.self, from: Data(json.utf8))
    }

    func testRowsListSystemThenBookThenChosenThenInstalledLanguagesWithoutDuplicates() {
        var input = ModelsRootRows.Input()
        input.systemLanguages = ["pt-BR", "en-US"]
        input.bookLanguages = ["fr", "pt"]
        input.choices = ["de": faber]
        input.installedLanguages = ["es", "pt_BR", "de"]
        let rows = ModelsRootRows.rows(input)
        XCTAssertEqual(rows.map(\.language), ["pt", "en", "fr", "de", "es"])
        XCTAssertEqual(rows.first { $0.language == "pt" }?.reasons, [.system, .book, .installed])
        XCTAssertEqual(rows.first { $0.language == "de" }?.reasons, [.choice, .installed])
    }

    func testABookLanguageWithoutAVoiceWarnsAndALanguageNoBookNeedsDoesNot() throws {
        var input = ModelsRootRows.Input()
        input.systemLanguages = ["en"]
        input.bookLanguages = ["pt", "fr"]
        input.resolution = { language in
            switch language {
            case "pt": return try? self.resolution("pt", .selected, selection: self.faber)
            case "fr": return try? self.resolution("fr", .missingModel)
            case "en": return try? self.resolution("en", .missingModel)
            default: return nil
            }
        }
        let rows = ModelsRootRows.rows(input)
        XCTAssertEqual(rows.first { $0.language == "fr" }?.needsVoice, true, "A library book is French and nothing reads it")
        XCTAssertEqual(rows.first { $0.language == "en" }?.needsVoice, false, "A system language alone never warns")
        XCTAssertEqual(rows.first { $0.language == "pt" }?.needsVoice, false)
    }

    func testAnUnresolvedLanguageNeverWarns() {
        var input = ModelsRootRows.Input()
        input.bookLanguages = ["ja"]
        XCTAssertEqual(ModelsRootRows.rows(input).first?.needsVoice, false, "Not resolved yet is not a missing voice")
    }

    func testBlankAndRegionTagsAreNormalizedToTheBaseLanguage() {
        var input = ModelsRootRows.Input()
        input.systemLanguages = ["", "pt-BR", "PT_pt"]
        XCTAssertEqual(ModelsRootRows.rows(input).map(\.language), ["pt"])
    }
}
