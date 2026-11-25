import XCTest
@testable import EpubToMp3

final class ToolbarSettingsParityTests: XCTestCase {
    func testInstalledSystemVoiceCanBeSelectedAsSecondaryWithoutChangingPrimary() throws {
        XCTAssertTrue(TtsSelection.selectableEngines.contains("system"),
                      "Apple must expose installed system speech as an offline fallback.")
        let (settings, defaults) = make()
        // An Edge primary is only kept with the online consent (without it the app moves to Piper on load).
        settings.allowOnlineAudioFallback = true
        settings.selectPrimaryNarration(.edgeDefault)
        settings.selectSecondaryNarration(.systemDefault)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.primaryTtsSelection, .edgeDefault)
        XCTAssertEqual(restored.ttsPreferences.secondary?.engine, "system")
        XCTAssertTrue(restored.ttsPreferences.allowOnlineFallback)
        let captured = NarrationConversionOptions.current(for: restored.ttsPreferences)
        restored.selectSecondaryNarration(nil)
        XCTAssertNil(AppSettings(defaults: defaults).secondaryTtsSelection)
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "system")
        XCTAssertEqual(captured.ttsPreferences?.primary.engine, "edge")
    }

    private func make() -> (AppSettings, UserDefaults) {
        let suite = "Toolbar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: d), d)
    }

    private func savedSelection(_ defaults: UserDefaults, _ key: String) -> TtsSelection? {
        SpeechPreferenceMigration.decodeSelection(defaults, key: key)
    }

    func testNewSpeechSettingsUseFaberWithNativeFallbackAndPersistExplicitNone() {
        let (settings, defaults) = make()
        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertFalse(settings.allowOnlineAudioFallback)
        XCTAssertEqual(savedSelection(defaults, "primaryTtsSelection"), .defaultPiper)
        XCTAssertEqual(savedSelection(defaults, "secondaryTtsSelection"), .systemDefault)
        XCTAssertNil(defaults.object(forKey: "audioEngine"))
        XCTAssertNil(defaults.object(forKey: "secondaryAudioEngine"))
        XCTAssertEqual(AppSettings(defaults: defaults).secondaryTtsSelection, .systemDefault)
        settings.selectSecondaryNarration(nil)
        XCTAssertNil(AppSettings(defaults: defaults).secondaryTtsSelection)
        XCTAssertEqual(AppSettings(defaults: defaults).primaryTtsSelection, .defaultPiper)
    }

    func testLoadingConsentedEdgeFallbackAdoptsNativeRecoveryWithoutChangingSelections() {
        let suite = "ConsentedLegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("piper", forKey: "audioEngine")
        defaults.set("edge", forKey: "secondaryAudioEngine")
        defaults.set(true, forKey: "allowOnlineAudioFallback")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(settings.secondaryTtsSelection, .edgeDefault)
        XCTAssertTrue(settings.ttsPreferences.allowOnlineFallback)
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.secondary?.engine, "edge")
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(savedSelection(defaults, "secondaryTtsSelection"), .edgeDefault)
        XCTAssertNil(defaults.object(forKey: "secondaryAudioEngine"), "The migrated engine key is retired.")
        XCTAssertNil(defaults.object(forKey: "ttsPreferencesVersion"))
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.ttsPreferences, settings.ttsPreferences)
    }

    func testExistingSpeechSettingsRetainPrimaryAndRecoverThroughSystem() {
        let suite = "LegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("edge", forKey: "audioEngine")
        defaults.set(true, forKey: "allowOnlineAudioFallback")   // without the consent Edge now moves to Piper
        defaults.set(GlobalVoiceMigration.currentVersion, forKey: GlobalVoiceMigration.versionKey)  // v1 rules only
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.primaryTtsSelection, .edgeDefault)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"))
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        settings.selectSecondaryNarration(.systemDefault)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.policyVersion, 2)
    }

    func testExistingExplicitNativeFallbackAdoptsRecoveryWithoutSettingsEdit() {
        let suite = "LegacyNativeSpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("piper", forKey: "audioEngine")
        defaults.set("system", forKey: "secondaryAudioEngine")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)
    }

    func testLoadingDuplicateLegacyFallbackClearsOnlySecondary() {
        let suite = "DuplicateLegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: "audioEngine")
        defaults.set("system", forKey: "secondaryAudioEngine")

        defaults.set(GlobalVoiceMigration.currentVersion, forKey: GlobalVoiceMigration.versionKey)  // v1 rules only
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.primaryTtsSelection, .systemDefault)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(settings.ttsPreferences.secondary)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).primaryEngine, "system")
    }

    func testUnreadableSavedSelectionStaysOnDiskUntilANewExplicitChoice() throws {
        let (_, defaults) = make()
        let unreadable = Data(#"{"model_id":"pt_BR-faber-medium"}"#.utf8)
        defaults.set(unreadable, forKey: "primaryTtsSelection")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper, "An unreadable choice narrates with the default.")
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertEqual(defaults.data(forKey: "primaryTtsSelection"), unreadable,
                       "Other edits and loading must not erase the saved primary.")
        XCTAssertEqual(AppSettings(defaults: defaults).primaryTtsSelection, .defaultPiper)
        settings.selectPrimaryNarration(.systemDefault)
        XCTAssertEqual(savedSelection(defaults, "primaryTtsSelection"), .systemDefault)
    }

    func testSavedUnconsentedEdgeSecondaryIsNeverSentAndSurvivesAPrimaryChange() throws {
        let (_, defaults) = make()
        let edge = try JSONEncoder().encode(TtsSelection.edgeDefault)
        defaults.set(edge, forKey: "secondaryTtsSelection")
        defaults.set(false, forKey: "allowOnlineAudioFallback")
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.ttsPreferences.secondary, "Edge never reaches conversion without consent.")
        settings.selectPrimaryNarration(.systemDefault)
        XCTAssertEqual(defaults.data(forKey: "secondaryTtsSelection"), edge,
                       "An unrelated primary change must not erase the saved secondary.")
    }

    func testPrimaryChangeKeepsADifferentSecondaryAndDropsARepeatedOne() {
        let (settings, _) = make()
        let english = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)
        settings.selectSecondaryNarration(english)
        settings.selectPrimaryNarration(.systemDefault)
        XCTAssertEqual(settings.secondaryTtsSelection, english)
        settings.selectPrimaryNarration(english)
        XCTAssertNil(settings.secondaryTtsSelection, "A secondary may not repeat the new primary.")
        XCTAssertEqual(settings.selectableSecondaryEngines, ["piper", "system"],
                       "Edge stays hidden without consent; the default Piper differs from this model.")
    }

    func testFontSizeStepperBoundaries() {
        let (s, _) = make()
        s.readerFontSize = 0
        s.readerFontSize = max(0, s.readerFontSize - 1)
        XCTAssertEqual(s.readerFontSize, 0)
        s.readerFontSize = 4
        s.readerFontSize = min(4, s.readerFontSize + 1)
        XCTAssertEqual(s.readerFontSize, 4)
    }

    func testFontFamilyPickerAllCasesPersist() {
        let (s, d) = make()
        for f in ReaderFontFamily.allCases {
            s.readerFontFamily = f
            XCTAssertEqual(AppSettings(defaults: d).readerFontFamily, f)
        }
    }

    func testThemePickerAllCasesPersist() {
        let (s, d) = make()
        for t in ReaderTheme.allCases {
            s.readerTheme = t
            XCTAssertEqual(AppSettings(defaults: d).readerTheme, t)
        }
    }

    func testLayoutPickerAllCasesPersist() {
        let (s, d) = make()
        for l in ReaderLayout.allCases {
            s.readerLayout = l
            XCTAssertEqual(AppSettings(defaults: d).readerLayout, l)
        }
    }

    func testLineSpacingDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [0.0, 4.0, 6.0, 8.0, 12.0, 16.0] {
            s.readerLineSpacing = v
            XCTAssertEqual(AppSettings(defaults: d).readerLineSpacing, v, accuracy: 0.001)
        }
    }

    func testMarginDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [16.0, 24.0, 36.0, 48.0, 64.0] {
            s.readerMargin = v
            XCTAssertEqual(AppSettings(defaults: d).readerMargin, v, accuracy: 0.001)
        }
    }

    func testColumnWidthDiscreteStepsAllPersist() {
        let (s, d) = make()
        for v in [520.0, 640.0, 720.0, 820.0, 920.0] {
            s.readerColumnWidth = v
            XCTAssertEqual(AppSettings(defaults: d).readerColumnWidth, v, accuracy: 0.001)
        }
    }

    func testPageTurnStylePickerAllCasesPersist() {
        let (s, d) = make()
        for style in PageTurnStyle.allCases {
            s.pageTurnStyle = style
            XCTAssertEqual(AppSettings(defaults: d).pageTurnStyle, style)
        }
    }

    func testPageTurnStyleDefaultsToFlip() {
        let (s, _) = make()
        XCTAssertEqual(s.pageTurnStyle, .flip)
    }

    func testIncompleteFaberInstallIsNotAdvertisedAsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("pt_BR-faber-medium")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = SpeechModelLibraryTarget.current()
        let target = SpeechModelLibraryTarget(
            language: "pt-BR", platform: current.platform, androidAPI: current.androidAPI,
            architecture: current.architecture, osVersion: current.osVersion, modelsRoot: root
        )
        let adapter = ConverterFFIAdapter()
        try Data([1]).write(to: directory.appendingPathComponent("model.onnx"))
        var snapshot = try adapter.speechModelSnapshot(target: target)
        XCTAssertFalse(snapshot.entries.first { $0.identity.modelID == "pt_BR-faber-medium" }?
            .installation.state == .installed, "An ONNX file alone is not a complete voice installation.")
        try Data([1]).write(to: directory.appendingPathComponent("model.onnx.json"))
        snapshot = try adapter.speechModelSnapshot(target: target)
        XCTAssertFalse(snapshot.entries.first { $0.identity.modelID == "pt_BR-faber-medium" }?
            .installation.state == .installed, "Unverified files must not claim a catalog installation.")
    }

    func testEdgeSecondaryRequiresConsentAndRevocationClearsPreference() throws {
        let (settings, defaults) = make()
        XCTAssertFalse(settings.selectableSecondaryEngines.contains("edge"))
        defaults.set(try JSONEncoder().encode(TtsSelection.edgeDefault), forKey: "secondaryTtsSelection")
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertNil(settings.secondaryTtsSelection, "Unconsented Edge must not be saved.")
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"), "Rejected assignment must clear a stale Edge preference.")
        XCTAssertNil(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.secondary, "Unconsented Edge must never reach conversion preferences.")
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.allowOnlineFallback, false)

        settings.selectPrimaryNarration(.edgeDefault)
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(.defaultPiper)
        XCTAssertEqual(savedSelection(defaults, "secondaryTtsSelection"), .defaultPiper)

        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(settings.secondaryTtsSelection, .defaultPiper, "Revocation may retain a non-Edge secondary.")
        XCTAssertEqual(savedSelection(defaults, "secondaryTtsSelection"), .defaultPiper)

        settings.selectPrimaryNarration(.defaultPiper)
        settings.allowOnlineAudioFallback = true
        XCTAssertTrue(settings.selectableSecondaryEngines.contains("edge"))
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.secondary?.engine, "edge")
        XCTAssertEqual(savedSelection(defaults, "secondaryTtsSelection"), .edgeDefault)

        settings.allowOnlineAudioFallback = false
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"))
        XCTAssertNil(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.secondary)
    }

    func testSecondaryCannotDuplicatePrimary() {
        let (settings, defaults) = make()
        settings.allowOnlineAudioFallback = true

        settings.selectSecondaryNarration(.defaultPiper)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"))

        settings.selectPrimaryNarration(.edgeDefault)
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"))
    }

    func testLegacyUnconsentedEdgeSecondaryIsNotMigratedOnLoad() {
        let suite = "Toolbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("edge", forKey: "secondaryAudioEngine")
        defaults.set(false, forKey: "allowOnlineAudioFallback")

        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: "secondaryTtsSelection"))
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "edge",
                       "A choice the new model cannot hold stays on disk untouched.")
        XCTAssertNil(settings.ttsPreferences.secondary)
        defaults.removePersistentDomain(forName: suite)
    }

    func testEdgePrimaryRemainsAvailableWithoutFallbackConsent() throws {
        let (settings, _) = make()
        settings.selectPrimaryNarration(.edgeDefault)

        XCTAssertEqual(settings.primaryTtsSelection, .edgeDefault)
        XCTAssertFalse(settings.allowOnlineAudioFallback)
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.primary.engine, "edge")
        XCTAssertEqual(NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences?.allowOnlineFallback, false)
    }

    @MainActor
    func testManualEdgePrimaryWithoutConsentKeepsSavedPreferences() async throws {
        let (settings, _) = make()
        let originalPreferences = settings.ttsPreferences
        var captured: ConversionOptions?
        var requestedJobID: String?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, options, _, _ in
            requestedJobID = jobID
            captured = options
            return .init(jobID: jobID, manifestJSON: Data(),
                         outputDirectory: URL(fileURLWithPath: "/unused-fixture"))
        }))
        model.selectedFile = URL(fileURLWithPath: "/unused-fixture.epub")
        model.engine = "edge"
        model.voice = "pt-BR-AntonioNeural"
        model.usesPreferences = false
        model.allowSecondary = false

        await model.submit()

        XCTAssertNotNil(requestedJobID)
        XCTAssertEqual(model.submittedJobId, requestedJobID)
        XCTAssertEqual(captured?.ttsPreferences?.primary.engine, "edge")
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, false)
        XCTAssertEqual(settings.ttsPreferences, originalPreferences)
    }

    func testFaberDefaultsAndExplicitEdgeChoicePersist() throws {
        let (settings, defaults) = make()
        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertFalse(settings.ttsPreferences.allowOnlineFallback)
        settings.allowOnlineAudioFallback = true
        settings.selectPrimaryNarration(.edgeDefault)
        settings.selectSecondaryNarration(.defaultPiper)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.primaryTtsSelection, .edgeDefault)
        XCTAssertEqual(restored.secondaryTtsSelection, .defaultPiper)
        let captured = NarrationConversionOptions.current(for: restored.ttsPreferences)
        restored.selectPrimaryNarration(.defaultPiper)
        XCTAssertEqual(captured.ttsPreferences?.primary.engine, "edge")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.encodedJSON().utf8)) as? [String: Any])
        let policy = try XCTUnwrap(fields["tts_preferences"] as? [String: Any])
        XCTAssertEqual(policy["allow_online_fallback"] as? Bool, true)
        XCTAssertEqual((policy["secondary"] as? [String: Any])?["model_id"] as? String, "pt_BR-faber-medium")
    }

    @MainActor
    func testManualOverrideIsStrictAndDoesNotChangePreferences() async throws {
        let (settings, _) = make()
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(.edgeDefault)
        var captured: ConversionOptions?
        var requestedJobID: String?
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, jobID, _, _, options, _, _ in
            requestedJobID = jobID
            captured = options
            return .init(jobID: jobID, manifestJSON: Data(),
                         outputDirectory: URL(fileURLWithPath: "/unused-fixture"))
        }))
        model.selectedFile = URL(fileURLWithPath: "/unused-fixture.epub")
        model.inheritedPreferences = settings.ttsPreferences
        model.engine = "piper"
        model.usesPreferences = false
        await model.submit()
        XCTAssertNotNil(requestedJobID)
        XCTAssertEqual(model.submittedJobId, requestedJobID)
        XCTAssertEqual(captured?.ttsPreferences?.primary.modelID, "pt_BR-faber-medium")
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, false)
        XCTAssertEqual(settings.secondaryTtsSelection, .edgeDefault)
        model.allowSecondary = true
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences?.secondary?.engine, "edge")
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, true)
        model.usesPreferences = true
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences, settings.ttsPreferences)
        model.usesPreferences = false
        model.allowSecondary = false
        model.engine = "edge"
        model.voice = ""
        model.allowSecondary = true
        XCTAssertNil(model.distinctManualSecondary)
        await model.submit()
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, false)
        model.voice = "pt-BR-AntonioNeural"
        XCTAssertNotNil(model.distinctManualSecondary, "Different Edge voices remain valid selections.")
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences?.secondary?.engine, "edge")
        model.allowSecondary = false
        await model.submit()
        XCTAssertEqual(captured?.ttsPreferences?.primary.voice, "pt-BR-AntonioNeural")
        XCTAssertNil(captured?.ttsPreferences?.primary.modelID)
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
    }

    func testAutoScrollTogglesBackAndForth() {
        let (s, _) = make()
        s.readerAutoScroll = true
        XCTAssertTrue(s.readerAutoScroll)
        s.readerAutoScroll = false
        XCTAssertFalse(s.readerAutoScroll)
    }

    func testEveryOverrideFlagToggles() {
        let (s, _) = make()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        XCTAssertTrue(s.readerOverrideFontFamily)
        XCTAssertTrue(s.readerOverrideFontSize)
        XCTAssertTrue(s.readerOverrideColours)
        XCTAssertTrue(s.readerBoldOverride)
        XCTAssertTrue(s.readerSuppressItalic)
    }

    func testLetterSpacingClampsAndPersists() {
        let (s, d) = make()
        s.readerLetterSpacing = 99
        XCTAssertEqual(s.readerLetterSpacing, 4, accuracy: 0.001)
        s.readerLetterSpacing = -99
        XCTAssertEqual(s.readerLetterSpacing, -2, accuracy: 0.001)
        s.readerLetterSpacing = 1.5
        XCTAssertEqual(AppSettings(defaults: d).readerLetterSpacing, 1.5, accuracy: 0.001)
    }

    func testWordSpacingClampsAndPersists() {
        let (s, d) = make()
        s.readerWordSpacing = 999
        XCTAssertEqual(s.readerWordSpacing, 8, accuracy: 0.001)
        s.readerWordSpacing = -5
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
        s.readerWordSpacing = 3
        XCTAssertEqual(AppSettings(defaults: d).readerWordSpacing, 3, accuracy: 0.001)
    }

    func testRestoreOriginalClearsAllOverrides() {
        let (s, _) = make()
        s.readerOverrideFontFamily = true
        s.readerOverrideFontSize = true
        s.readerOverrideColours = true
        s.readerBoldOverride = true
        s.readerSuppressItalic = true
        s.readerLetterSpacing = 2
        s.readerWordSpacing = 4
        s.restoreOriginal()
        XCTAssertFalse(s.readerOverrideFontFamily)
        XCTAssertFalse(s.readerOverrideFontSize)
        XCTAssertFalse(s.readerOverrideColours)
        XCTAssertFalse(s.readerBoldOverride)
        XCTAssertFalse(s.readerSuppressItalic)
        XCTAssertEqual(s.readerLetterSpacing, 0, accuracy: 0.001)
        XCTAssertEqual(s.readerWordSpacing, 0, accuracy: 0.001)
    }

    func testRestoreOriginalDoesNotTouchPreferenceFields() {
        let (s, _) = make()
        s.readerLayout = .paginated
        s.readerTheme = .sepia
        s.readerAutoScroll = false
        s.readerOverrideFontFamily = true
        s.restoreOriginal()
        XCTAssertEqual(s.readerLayout, .paginated)
        XCTAssertEqual(s.readerTheme, .sepia)
        XCTAssertFalse(s.readerAutoScroll)
        XCTAssertFalse(s.readerOverrideFontFamily)
    }
}
