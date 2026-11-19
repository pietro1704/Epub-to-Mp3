import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class NarrationConversionOptionsTests: XCTestCase {
    private let preferences = TtsPreferences(primary: .defaultPiper, secondary: .systemDefault,
                                             allowOnlineFallback: false, policyVersion: 3)
    private let modelsRoot = URL(fileURLWithPath: "/tmp/narration-models", isDirectory: true)
    private let catalog = TtsCatalog(version: 3, models: [], providers: [
        TtsCatalog.Provider(provider: "system", runtime: "system-runtime", targets: ["macos"]),
    ])

    func testCatalogCapturesTheSelectionsForTheTarget() {
        let prepared = NarrationConversionOptions.prepare(preferences, loadCatalog: { catalog },
                                                          modelsRoot: modelsRoot, espeakDataDirectory: "/espeak",
                                                          target: "macos")

        XCTAssertNil(prepared.catalogFailure)
        XCTAssertEqual(prepared.options.ttsPreferences, catalog.capture(preferences, target: "macos"))
        XCTAssertEqual(prepared.options.ttsPreferences?.secondary?.session?.runtime, "system-runtime")
        XCTAssertEqual(prepared.options.engine, "piper")
        XCTAssertEqual(prepared.options.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(prepared.options.modelsRoot, modelsRoot.path)
        XCTAssertEqual(prepared.options.espeakDataDirectory, "/espeak")

        let otherTarget = NarrationConversionOptions.prepare(preferences, loadCatalog: { catalog },
                                                             modelsRoot: modelsRoot, espeakDataDirectory: nil,
                                                             target: "ios")
        XCTAssertNil(otherTarget.options.ttsPreferences?.secondary?.session)
    }

    func testUnreadableCatalogSendsTheSelectionsAsChosenAndReportsWhy() {
        let prepared = NarrationConversionOptions.prepare(preferences,
                                                          loadCatalog: { throw EmbeddedConverterError.artifactUnavailable },
                                                          modelsRoot: modelsRoot, espeakDataDirectory: "/espeak",
                                                          target: "macos")

        XCTAssertEqual(prepared.catalogFailure as? EmbeddedConverterError, .artifactUnavailable)
        XCTAssertEqual(prepared.options.ttsPreferences, preferences)
        XCTAssertEqual(prepared.options.engine, "piper")
        XCTAssertEqual(prepared.options.modelsRoot, modelsRoot.path)
        XCTAssertEqual(prepared.options.espeakDataDirectory, "/espeak")
    }

    func testModelsRootAndEspeakDataAreSentForEveryPrimaryEngine() {
        let system = TtsPreferences(primary: .systemDefault, secondary: nil, allowOnlineFallback: false, policyVersion: 2)
        let prepared = NarrationConversionOptions.prepare(system, loadCatalog: { catalog },
                                                          modelsRoot: modelsRoot, espeakDataDirectory: "/espeak",
                                                          target: "macos")

        XCTAssertEqual(prepared.options.engine, "system")
        XCTAssertNil(prepared.options.modelID)
        XCTAssertEqual(prepared.options.modelsRoot, modelsRoot.path)
        XCTAssertEqual(prepared.options.espeakDataDirectory, "/espeak")
    }
}
