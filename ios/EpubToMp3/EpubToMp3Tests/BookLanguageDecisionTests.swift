import XCTest
@testable import EpubToMp3

final class BookLanguageDecisionTests: XCTestCase {
    func testPartialCorrectionAndAutomaticResetPreserveTheSurroundingManualDecision() throws {
        let suite = "PassageLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookLanguageCorrections(defaults: defaults)
        let original = PassageLanguageCorrection(chapterIndex: 2, start: 0, end: 100, language: "pt-BR")
        let selected = PassageLanguageCorrection(chapterIndex: 2, start: 20, end: 40, language: "en")
        try store.set("pt-BR", bookID: "book", passage: original)
        try store.set("en", bookID: "book", passage: selected)
        XCTAssertEqual(try store.decision(bookID: "book").passages, [
            .init(chapterIndex: 2, start: 0, end: 20, language: "pt-BR"),
            .init(chapterIndex: 2, start: 40, end: 100, language: "pt-BR"), selected])
        try store.set(nil, bookID: "book", passage: selected)
        XCTAssertEqual(try store.decision(bookID: "book").passages.count, 2)
        XCTAssertEqual(try store.decision(bookID: "book").passages.last?.end, 100)
    }

    func testCorrectionsRemainScopedToContentIdentityAndManualChoicesWin() throws {
        let name = "BookLanguageDecisionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BookLanguageCorrections(defaults: defaults)
        try store.set("pt-PT", bookID: "first-content-hash")
        let passage = PassageLanguageCorrection(chapterIndex: 4, start: 10, end: 80, language: "fr")
        try store.set("fr", bookID: "first-content-hash", passage: passage)
        let restored = BookLanguageCorrections(defaults: defaults)
        let options = try restored.applying(to: ConversionOptions(), bookID: "first-content-hash")
        XCTAssertEqual(options.language, "pt-PT")
        XCTAssertEqual(options.languageOverrides, [passage])
        XCTAssertNil(try restored.applying(to: ConversionOptions(), bookID: "changed-content-hash").language)
        var explicit = ConversionOptions()
        explicit.language = "en"
        XCTAssertEqual(try restored.applying(to: explicit, bookID: "first-content-hash").language, "en")
        try store.set(nil, bookID: "first-content-hash", passage: passage)
        XCTAssertEqual(try store.decision(bookID: "first-content-hash").passages, [])
        XCTAssertEqual(try store.decision(bookID: "first-content-hash").bookLanguage, "pt-PT")
        try store.set(nil, bookID: "first-content-hash")
        XCTAssertNil(try store.decision(bookID: "first-content-hash").bookLanguage)
    }

    func testLegacyModelMismatchUsesTheSameNativeRecoveryContract() throws {
        let error = EmbeddedConverterError.conversionFailed(
            #"Faber medium supports Portuguese [[tts_language_mismatch_v1]]{"language":"en-GB","model_id":"pt_BR-faber-medium"}[[/tts_language_mismatch_v1]]"#)
        let mismatch = try XCTUnwrap(TtsLanguageMismatch.decode(error))
        XCTAssertEqual(mismatch.language, "en-GB")
        XCTAssertEqual(mismatch.modelID, "pt_BR-faber-medium")
    }

    func testCompatibleSecondaryRecoveryKeepsPrimaryAndAutomaticLanguage() {
        var options = ConversionOptions()
        options.ttsPreferences = TtsPreferences(primary: .selected(.piper), secondary: nil,
            allowOnlineFallback: false, policyVersion: 3)
        let candidate = TtsRecoveryCandidate(name: "English", selection: .selected(.system))
        let result = options.recovering(with: candidate, language: "en-US")
        XCTAssertEqual(result.ttsPreferences?.primary, options.ttsPreferences?.primary)
        XCTAssertEqual(result.ttsPreferences?.secondary, candidate.selection)
        XCTAssertNil(result.language)
        XCTAssertEqual(result.ttsPreferences?.policyVersion, 3)
    }

    func testRenderedSelectionMapsToSourceScalarsAndRejectsAmbiguousText() throws {
        let source = "😀 original   English passage. Outra passagem."
        let rendered = "😀 original English passage. Outra passagem."
        let range = (rendered as NSString).range(of: "English passage.")
        let passage = try XCTUnwrap(ReaderLanguageSelection.passage(rendered: rendered,
            range: range, source: source, chapterIndex: 2))
        XCTAssertEqual(passage.start, "😀 original   ".unicodeScalars.count)
        XCTAssertEqual(passage.end - passage.start, "English passage.".unicodeScalars.count)
        XCTAssertEqual(passage.chapterIndex, 2)
        XCTAssertNil(ReaderLanguageSelection.passage(rendered: "repeat", range: NSRange(location: 0, length: 6),
            source: "repeat repeat", chapterIndex: 0))
    }

    func testRepeatedPassageCorrectionTargetsTheSelectedOccurrence() throws {
        let source = "😀 First   repeated passage.\nSecond repeated passage."
        let rendered = "😀 First repeated passage. Second repeated passage."
        let range = (rendered as NSString).range(of: "repeated passage.", options: .backwards)
        let passage = try XCTUnwrap(ReaderLanguageSelection.passage(rendered: rendered,
            range: range, source: source, chapterIndex: 3))
        XCTAssertEqual(passage.start, "😀 First   repeated passage.\nSecond ".unicodeScalars.count)
        XCTAssertEqual(passage.end - passage.start, "repeated passage.".unicodeScalars.count)
        XCTAssertEqual(passage.chapterIndex, 3)
        XCTAssertNil(ReaderLanguageSelection.passage(rendered: rendered,
            range: NSRange(location: 1, length: 1), source: source, chapterIndex: 3))
    }
}
