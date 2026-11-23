import XCTest
@testable import EpubToMp3

final class ModelsByLanguageTests: XCTestCase {
    // MARK: fixtures

    private func entry(
        provider: String = "piper", id: String, name: String, quality: SpeechModelSnapshot.Quality = .medium,
        installed: Bool, compatible: Bool = true, installable: Bool = true, bytes: UInt64? = 10
    ) -> SpeechModelSnapshot.Entry {
        .init(identity: .init(provider: provider, runtime: provider, modelID: id, modelRevision: "fixture"),
              presentation: .init(modelName: name, familyName: "Family", quality: quality, voiceChoices: []),
              languageEvidence: .init(routingTags: [], exactTags: []),
              distribution: .init(installable: installable, downloadBytes: bytes, installedBytes: nil),
              licence: .init(id: nil, category: "unknown", evidenceURL: nil, termsFingerprint: nil,
                             requiresAcceptance: false, validation: "unknown"),
              compatibility: .init(compatible: compatible, reasons: []),
              installation: .init(state: installed ? .installed : .missing, verifiedRevision: nil, installedBytes: nil),
              readiness: .init(state: installed ? .ready : .notInspected, activeRuntimeRevision: nil, failure: nil),
              selection: .init(selectable: installed && compatible, reasons: []))
    }

    private func snapshot(_ entries: [SpeechModelSnapshot.Entry], language: String) throws -> SpeechModelSnapshot {
        // The Rust snapshot is decoded, never assembled: round-trip a minimal document.
        let document: [String: Any] = [
            "schema_version": 3, "generated_from_catalog_revision": "fixture",
            "target": ["language": language], "entries": [],
            "default_selection": ["version": 2, "provider": "piper", "runtime": "piper",
                                  "model_id": NSNull(), "model_revision": NSNull(), "voice": NSNull(), "options": [:]],
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let decoded = try SpeechModelSnapshot.decode(data)
        return SpeechModelSnapshot(schemaVersion: decoded.schemaVersion,
                                   generatedFromCatalogRevision: decoded.generatedFromCatalogRevision,
                                   defaultSelection: decoded.defaultSelection, target: decoded.target, entries: entries)
    }

    private func state(
        choices: [String: TtsSelection] = [:], consent: Bool = false, system: Set<String> = []
    ) throws -> ModelsByLanguageViewState {
        let pt = try snapshot([
            entry(id: "pt_BR-faber-medium", name: "Faber", installed: true),
            entry(id: "pt_BR-cadu-medium", name: "Cadu", installed: false, bytes: 63_000_000),
            entry(id: "pt_BR-jeff-medium", name: "Jeff", installed: false, installable: false),
            entry(provider: "edge", id: "edge", name: "Edge", installed: false),
        ], language: "pt")
        let en = try snapshot([
            entry(id: "en_US-ljspeech-high", name: "LJ Speech", quality: .high, installed: false),
            entry(id: "en_GB-cori-medium", name: "Cori", installed: true),
        ], language: "en")
        return .make(languages: [.init(tag: "pt", snapshot: pt), .init(tag: "en", snapshot: en)],
                     choices: choices, allowOnlineFallback: consent, systemVoiceLanguages: system)
    }

    // MARK: view state

    func testRowsAreGroupedByLanguageAndSplitByKind() throws {
        let sections = try state().sections
        XCTAssertEqual(sections.map(\.language), ["pt", "en"])
        let pt = sections[0]
        XCTAssertEqual(pt.local.map(\.title), ["Faber", "Cadu", "Jeff"])
        XCTAssertEqual(pt.online.map(\.title), ["Edge"])
    }

    func testDimmingFollowsInstallationAvailabilityAndConsent() throws {
        let pt = try state().sections[0]
        func row(_ title: String) throws -> ModelsByLanguageViewState.Row { try XCTUnwrap(pt.rows.first { $0.title == title }) }
        XCTAssertFalse(try row("Faber").isDimmed)
        XCTAssertEqual(try row("Faber").availability, .ready)
        XCTAssertTrue(try row("Cadu").isDimmed)
        XCTAssertEqual(try row("Cadu").availability, .downloadable(bytes: 63_000_000))
        XCTAssertEqual(try row("Jeff").availability, .unavailable, "Not installable: dimmed, nothing to download.")
        XCTAssertEqual(try row("Edge").availability, .needsConsent)
        let consented = try state(consent: true).sections[0].rows.first { $0.title == "Edge" }
        XCTAssertEqual(consented?.availability, .ready)
    }

    func testTheInstalledSystemVoiceIsListedPerLanguageAndNeverDimmed() throws {
        let sections = try state(system: ["pt-BR"]).sections
        let system = try XCTUnwrap(sections[0].rows.first { $0.selection.engine == "system" })
        XCTAssertEqual(system.kind, .local)
        XCTAssertFalse(system.isDimmed)
        XCTAssertEqual(system.availability, .ready)
        XCTAssertFalse(sections[1].rows.contains { $0.selection.engine == "system" }, "No English system voice installed.")
    }

    func testTheChoiceMarksExactlyOneRowPerLanguage() throws {
        let faber = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)
        let sections = try state(choices: ["pt": faber]).sections
        XCTAssertEqual(sections[0].rows.filter(\.isChosen).map(\.title), ["Faber"])
        XCTAssertNil(sections[1].chosen, "English has no choice: automatic.")
        let system = try state(choices: ["pt": .systemDefault], system: ["pt"]).sections[0]
        XCTAssertEqual(system.chosen?.selection.engine, "system")
    }

    func testReadyRowsSortBeforeDimmedOnesAndHighQualityFirst() throws {
        let en = try state().sections[1]
        XCTAssertEqual(en.local.map(\.title), ["Cori", "LJ Speech"], "Installed first, then the downloadable one.")
    }

    // MARK: persistence

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "models-by-language-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testLanguageChoicesPersistByBaseLanguageAndSurviveRelaunch() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SpeechPreferences(defaults: defaults)
        XCTAssertTrue(preferences.languageModelChoices.isEmpty, "Absent means automatic.")
        let cadu = TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil)
        preferences.selectLanguageModel(cadu, for: "pt-BR")
        XCTAssertEqual(preferences.languageModelChoices["pt"], cadu)
        let relaunched = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(relaunched.languageModelChoices, ["pt": cadu])
        relaunched.clearLanguageModel(for: "PT_br")
        XCTAssertTrue(SpeechPreferences(defaults: defaults).languageModelChoices.isEmpty)
    }

    func testChoicesDoNotChangeThePrimaryOrSecondary() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SpeechPreferences(defaults: defaults)
        let primary = preferences.primaryTtsSelection, secondary = preferences.secondaryTtsSelection
        preferences.selectLanguageModel(TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil), for: "en")
        XCTAssertEqual(preferences.primaryTtsSelection, primary)
        XCTAssertEqual(preferences.secondaryTtsSelection, secondary)
    }

    func testUndecodableStoredChoicesAreLeftOnDiskUntilANewChoice() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: SpeechPreferences.languageModelChoicesKey)
        let preferences = SpeechPreferences(defaults: defaults)
        XCTAssertTrue(preferences.languageModelChoices.isEmpty)
        XCTAssertEqual(defaults.data(forKey: SpeechPreferences.languageModelChoicesKey), garbage)
    }

    // MARK: contract encoding and the real Rust library

    func testResolutionRequestEncodesTheContractKeys() throws {
        var request = LanguageModelResolutionRequest(bookLanguage: "pt-BR", platform: "Macos")
        request.perLanguageChoices = ["pt": TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)]
        request.installedModelIDs = ["pt_BR-faber-medium"]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["book_language"] as? String, "pt-BR")
        XCTAssertEqual(json["platform"] as? String, "Macos")
        XCTAssertEqual(json["allow_automatic_system_voice_fallback"] as? Bool, true)
        XCTAssertEqual(json["installed_model_ids"] as? [String], ["pt_BR-faber-medium"])
        let choices = try XCTUnwrap(json["per_language_choices"] as? [String: [String: Any]])
        XCTAssertEqual(choices["pt"]?["model_id"] as? String, "pt_BR-faber-medium")
    }

    private func bundledAdapter() throws -> ConverterFFIAdapter {
        #if os(iOS)
        let library = Bundle.main.bundleURL.appendingPathComponent("Frameworks/libconverter_ffi.dylib")
        #else
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL).appendingPathComponent("libconverter_ffi.dylib")
        #endif
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "No embedded Rust library")
        return ConverterFFIAdapter(libraryURL: library)
    }

    func testBundledRustResolvesLanguagesAndModelsThroughTheContract() throws {
        let adapter = try bundledAdapter()
        let languages = try adapter.catalogLanguages(platform: LanguageModelResolutionRequest.currentPlatform.lowercased())
        XCTAssertTrue(languages.contains { $0.tag == "pt" } && languages.contains { $0.tag == "en" })

        var request = LanguageModelResolutionRequest(bookLanguage: "pt-BR", platform: LanguageModelResolutionRequest.currentPlatform)
        request.installedModelIDs = ["pt_BR-faber-medium"]
        let selected = try adapter.resolveLanguageModel(request)
        XCTAssertEqual(selected.status, .selected)
        XCTAssertEqual(selected.source, .automatic)
        XCTAssertEqual(selected.selection?.modelID, "pt_BR-faber-medium")

        request.bookLanguage = "en"
        let missing = try adapter.resolveLanguageModel(request)
        XCTAssertEqual(missing.status, .missingModel)
        XCTAssertNil(missing.selection)
        XCTAssertFalse(missing.missing?.suggested.isEmpty ?? true)

        request.systemVoices = ["en-US"]
        XCTAssertEqual(try adapter.resolveLanguageModel(request).status, .systemFallback)
        request.allowAutomaticSystemVoiceFallback = false
        XCTAssertEqual(try adapter.resolveLanguageModel(request).status, .missingModel)

        XCTAssertThrowsError(try adapter.bookLanguage(at: URL(fileURLWithPath: "/nonexistent/book.epub"))) {
            XCTAssertTrue(String(describing: $0).contains("book not found"), "\($0)")
        }
    }
}
