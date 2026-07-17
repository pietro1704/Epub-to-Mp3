import XCTest
@testable import EpubToMp3

/// Tests for `VoiceSelector` — NLLanguageRecognizer-based Edge-TTS voice
/// selection extracted from BookOpenView.
final class VoiceSelectorTests: XCTestCase {

    // MARK: - English

    func testDeclaredEnglishLanguageOverridesAmbiguousText() {
        XCTAssertEqual(
            VoiceSelector.edgeVoice(for: "The Fellowship of the Ring", declaredLanguage: "en"),
            "en-US-AriaNeural"
        )
    }

    func testDeclaredPortugueseLanguageSelectsPortugueseVoice() {
        XCTAssertEqual(
            VoiceSelector.edgeVoice(for: "The Fellowship of the Ring", declaredLanguage: "pt-BR"),
            "pt-BR-FranciscaNeural"
        )
    }

    func testEnglishTextReturnsAriaNeural() {
        let text = """
        The sun rose over the distant mountains, casting long shadows across \
        the valley below. Birds began their morning chorus as the fog slowly \
        lifted from the river. It was going to be a beautiful day, the kind \
        that makes you grateful to be alive and breathing fresh mountain air.
        """
        let voice = VoiceSelector.edgeVoice(for: text)
        XCTAssertEqual(voice, "en-US-AriaNeural")
    }

    // MARK: - Portuguese

    func testPortugueseTextReturnsFranciscaNeural() {
        let text = """
        O sol nascia por trás das montanhas distantes, projetando longas sombras \
        sobre o vale abaixo. Os pássaros começavam seu coro matinal enquanto a \
        neblina se dissipava lentamente do rio. Seria um dia lindo, daqueles que \
        fazem a gente agradecer por estar vivo e respirando o ar fresco da serra.
        """
        let voice = VoiceSelector.edgeVoice(for: text)
        XCTAssertEqual(voice, "pt-BR-FranciscaNeural")
    }

    // MARK: - Spanish

    func testSpanishTextReturnsDaliaNeural() {
        let text = """
        El sol se elevaba sobre las montañas lejanas, proyectando largas sombras \
        sobre el valle. Los pájaros comenzaban su coro matutino mientras la niebla \
        se disipaba lentamente del río. Iba a ser un día hermoso, de esos que te \
        hacen agradecer estar vivo y respirar el aire fresco de la montaña.
        """
        let voice = VoiceSelector.edgeVoice(for: text)
        XCTAssertEqual(voice, "es-MX-DaliaNeural")
    }

    // MARK: - French

    func testFrenchTextReturnsDeniseNeural() {
        let text = """
        Le soleil se levait derrière les montagnes lointaines, projetant de longues \
        ombres sur la vallée en contrebas. Les oiseaux commençaient leur chœur matinal \
        tandis que le brouillard se dissipait lentement de la rivière. Ce serait une \
        belle journée, le genre qui vous fait apprécier d'être en vie.
        """
        let voice = VoiceSelector.edgeVoice(for: text)
        XCTAssertEqual(voice, "fr-FR-DeniseNeural")
    }

    // MARK: - German

    func testGermanTextReturnsKatjaNeural() {
        let text = """
        Die Sonne ging hinter den fernen Bergen auf und warf lange Schatten über \
        das Tal. Die Vögel begannen ihren Morgenchor, während sich der Nebel \
        langsam vom Fluss lichtete. Es würde ein wunderschöner Tag werden, einer \
        von der Sorte, die einen dankbar macht, am Leben zu sein.
        """
        let voice = VoiceSelector.edgeVoice(for: text)
        XCTAssertEqual(voice, "de-DE-KatjaNeural")
    }

    // MARK: - Fallback for unknown / short text

    func testEmptyTextFallsBackToEnglish() {
        let voice = VoiceSelector.edgeVoice(for: "")
        XCTAssertEqual(voice, "en-US-AriaNeural")
    }

    func testNilLanguageFallsBackToEnglish() {
        let voice = VoiceSelector.voiceName(for: nil)
        XCTAssertEqual(voice, "en-US-AriaNeural")
    }
}
