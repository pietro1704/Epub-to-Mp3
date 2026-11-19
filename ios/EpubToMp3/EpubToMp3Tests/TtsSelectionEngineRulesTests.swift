import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Pins the engine rules that every voice control shares through `TtsSelection`.
final class TtsSelectionEngineRulesTests: XCTestCase {
    func testDefaultPiperSelectionIsFaber() {
        XCTAssertEqual(TtsSelection.defaultPiper,
                       TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil))
        XCTAssertEqual(TtsSelection.defaultModelID(forEngine: "piper"), "pt_BR-faber-medium")
        XCTAssertNil(TtsSelection.defaultModelID(forEngine: "system"))
        XCTAssertNil(TtsSelection.defaultModelID(forEngine: "edge"))
        XCTAssertNil(TtsSelection.defaultModelID(forEngine: "melotts"))
    }

    func testEngineDefaultsCarryOnlyTheFaberModelAndTheGivenVoice() {
        XCTAssertEqual(TtsSelection.systemDefault, TtsSelection(engine: "system", modelID: nil, voice: nil))
        XCTAssertEqual(TtsSelection.edgeDefault, TtsSelection(engine: "edge", modelID: nil, voice: nil))
        XCTAssertEqual(TtsSelection.engineDefault("piper", voice: "v"),
                       TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: "v"))
        XCTAssertNil(TtsSelection.engineDefault("edge").session)
    }

    func testSelectableEnginesAreOfferedPiperSystemEdge() {
        XCTAssertEqual(TtsSelection.selectableEngines, ["piper", "system", "edge"])
    }

    func testEngineDisplayNamesAndUnknownEngines() {
        XCTAssertEqual(TtsSelection.displayName(forEngine: "piper"), "Piper")
        XCTAssertEqual(TtsSelection.displayName(forEngine: "edge"), "Edge")
        XCTAssertEqual(TtsSelection.displayName(forEngine: "system"), L10n.string("settings.systemTts"))
        XCTAssertNil(TtsSelection.displayName(forEngine: "melotts"))
        XCTAssertNil(TtsSelection.displayName(forEngine: ""))
    }

    func testEnginePredicatesCompareTheEngineIdentityOnly() {
        let customPiper = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: "x")
        XCTAssertTrue(customPiper.isPiper)
        XCTAssertFalse(customPiper.isSystem || customPiper.isEdge)
        XCTAssertTrue(TtsSelection.systemDefault.isSystem)
        XCTAssertTrue(TtsSelection.edgeDefault.isEdge)
        XCTAssertFalse(TtsSelection(engine: "Piper", modelID: nil, voice: nil).isPiper,
                       "Engine identities are exact transport strings.")
    }

    func testEdgeFallbackNeedsConsentAndOtherEnginesDoNot() {
        XCTAssertFalse(TtsSelection.edgeDefault.isAllowedAsFallback(allowOnlineFallback: false))
        XCTAssertTrue(TtsSelection.edgeDefault.isAllowedAsFallback(allowOnlineFallback: true))
        XCTAssertTrue(TtsSelection.systemDefault.isAllowedAsFallback(allowOnlineFallback: false))
        XCTAssertTrue(TtsSelection.defaultPiper.isAllowedAsFallback(allowOnlineFallback: false))
    }

    func testSecondaryMustDifferFromPrimaryAndEdgeNeedsConsent() {
        let piper = TtsSelection.defaultPiper
        XCTAssertFalse(piper.canBeSecondary(to: piper, allowOnlineFallback: true),
                       "A secondary that repeats the primary request is rejected.")
        XCTAssertFalse(TtsSelection.systemDefault.canBeSecondary(to: .systemDefault, allowOnlineFallback: false))
        XCTAssertTrue(TtsSelection.systemDefault.canBeSecondary(to: piper, allowOnlineFallback: false))
        XCTAssertFalse(TtsSelection.edgeDefault.canBeSecondary(to: piper, allowOnlineFallback: false),
                       "Edge needs explicit online consent.")
        XCTAssertTrue(TtsSelection.edgeDefault.canBeSecondary(to: piper, allowOnlineFallback: true))
        XCTAssertFalse(TtsSelection.edgeDefault.canBeSecondary(to: .edgeDefault, allowOnlineFallback: true))
        let english = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)
        XCTAssertTrue(english.canBeSecondary(to: piper, allowOnlineFallback: false),
                      "A different Piper model is a different request.")
        let antonio = TtsSelection.engineDefault("edge", voice: "pt-BR-AntonioNeural")
        XCTAssertTrue(antonio.canBeSecondary(to: .edgeDefault, allowOnlineFallback: true),
                      "A different Edge voice is a different request.")
    }

    func testSelectedEngineOptionsResolveUnknownEnginesToFaber() {
        let piper = ConversionOptions.selectedEngine("piper")
        XCTAssertEqual(piper.engine, "piper")
        XCTAssertEqual(piper.modelID, "pt_BR-faber-medium")
        let system = ConversionOptions.selectedEngine("system")
        XCTAssertEqual(system.engine, "system")
        XCTAssertNil(system.modelID)
        XCTAssertNil(system.modelsRoot)
        let unknown = ConversionOptions.selectedEngine("kokoro")
        XCTAssertEqual(unknown.engine, "piper")
        XCTAssertEqual(unknown.modelID, "pt_BR-faber-medium")
    }
}
