import XCTest
@testable import EpubToMp3

final class ToolbarSettingsParityTests: XCTestCase {
    func testInstalledSystemVoiceCanBeSelectedAsSecondaryWithoutChangingPrimary() throws {
        let system = try XCTUnwrap(AudioEnginePreference.supportedPreferences.first { $0.rawValue == "system" },
                                  "Apple must expose installed system speech as an offline fallback.")
        let (settings, defaults) = make()
        settings.audioEngine = .edge
        settings.secondaryAudioEngine = system
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.audioEngine, .edge)
        XCTAssertEqual(restored.ttsPreferences.secondary?.engine, "system")
        XCTAssertFalse(restored.ttsPreferences.allowOnlineFallback)
        let captured = restored.conversionOptions
        restored.secondaryAudioEngine = nil
        XCTAssertNil(AppSettings(defaults: defaults).secondaryAudioEngine)
        XCTAssertEqual(captured.ttsPreferences?.secondary?.engine, "system")
        XCTAssertEqual(captured.ttsPreferences?.primary.engine, "edge")
    }

    private func make() -> (AppSettings, UserDefaults) {
        let suite = "Toolbar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: d), d)
    }

    func testNewSpeechSettingsUseFaberWithNativeFallbackAndPersistExplicitNone() {
        let (settings, defaults) = make()
        XCTAssertEqual(settings.audioEngine, .piper)
        XCTAssertEqual(settings.secondaryAudioEngine, .system)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertFalse(settings.allowOnlineAudioFallback)
        XCTAssertEqual(defaults.string(forKey: AppSettings.audioEngineKey), "piper")
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "system")
        XCTAssertEqual(AppSettings(defaults: defaults).secondaryAudioEngine, .system)
        settings.secondaryAudioEngine = nil
        XCTAssertNil(AppSettings(defaults: defaults).secondaryAudioEngine)
        XCTAssertEqual(AppSettings(defaults: defaults).audioEngine, .piper)
    }

    func testLoadingConsentedEdgeFallbackPreservesLegacyPolicyUntilEdited() {
        let suite = "ConsentedLegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("piper", forKey: AppSettings.audioEngineKey)
        defaults.set("edge", forKey: "secondaryAudioEngine")
        defaults.set(true, forKey: "allowOnlineAudioFallback")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.audioEngine, .piper)
        XCTAssertEqual(settings.secondaryAudioEngine, .edge)
        XCTAssertTrue(settings.ttsPreferences.allowOnlineFallback)
        XCTAssertEqual(settings.conversionOptions.ttsPreferences?.secondary?.engine, "edge")
        XCTAssertNil(settings.ttsPreferences.policyVersion)
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "edge")
        XCTAssertNil(defaults.object(forKey: "ttsPreferencesVersion"))
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.ttsPreferences, settings.ttsPreferences)
    }

    func testExistingSpeechSettingsRetainExplicitPrimaryAndNoFallback() {
        let suite = "LegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.audioEngine, .edge)
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        XCTAssertNil(settings.ttsPreferences.policyVersion)
        settings.secondaryAudioEngine = .system
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.policyVersion, 2)
    }

    func testExistingExplicitNativeFallbackKeepsLegacyRecoveryUntilSettingsEdit() {
        let suite = "LegacyNativeSpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("piper", forKey: AppSettings.audioEngineKey)
        defaults.set("system", forKey: "secondaryAudioEngine")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.secondaryAudioEngine, .system)
        XCTAssertNil(settings.ttsPreferences.policyVersion)
        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(settings.secondaryAudioEngine, .system)
    }

    func testLoadingDuplicateLegacyFallbackClearsOnlySecondary() {
        let suite = "DuplicateLegacySpeech.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("system", forKey: AppSettings.audioEngineKey)
        defaults.set("system", forKey: "secondaryAudioEngine")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.audioEngine, .system)
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(settings.ttsPreferences.secondary)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        XCTAssertNil(settings.ttsPreferences.policyVersion)
        XCTAssertEqual(AppSettings(defaults: defaults).audioEngine, .system)
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
        try Data([1]).write(to: directory.appendingPathComponent("model.onnx"))
        XCTAssertFalse(AppSettings.isFaberInstalled(modelsRoot: root), "An ONNX file alone is not a complete voice installation.")
        try Data([1]).write(to: directory.appendingPathComponent("model.onnx.json"))
        XCTAssertFalse(AppSettings.isFaberInstalled(modelsRoot: root), "Unverified files must not claim a catalog installation.")
    }

    func testEdgeSecondaryRequiresConsentAndRevocationClearsPreference() throws {
        let (settings, defaults) = make()
        XCTAssertFalse(settings.selectableSecondaryAudioEngines.contains(.edge))
        defaults.set("edge", forKey: "secondaryAudioEngine")
        settings.secondaryAudioEngine = .edge
        XCTAssertNil(settings.secondaryAudioEngine, "Unconsented Edge must not be saved.")
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"), "Rejected assignment must clear a stale Edge preference.")
        XCTAssertNil(settings.conversionOptions.ttsPreferences?.secondary, "Unconsented Edge must never reach conversion preferences.")
        XCTAssertEqual(settings.conversionOptions.ttsPreferences?.allowOnlineFallback, false)

        settings.audioEngine = .edge
        settings.allowOnlineAudioFallback = true
        settings.secondaryAudioEngine = .piper
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "piper")

        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(settings.secondaryAudioEngine, .piper, "Revocation may retain a non-Edge secondary.")
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "piper")

        settings.audioEngine = .piper
        settings.allowOnlineAudioFallback = true
        XCTAssertTrue(settings.selectableSecondaryAudioEngines.contains(.edge))
        settings.secondaryAudioEngine = .edge
        XCTAssertEqual(settings.conversionOptions.ttsPreferences?.secondary?.engine, "edge")
        XCTAssertEqual(defaults.string(forKey: "secondaryAudioEngine"), "edge")

        settings.allowOnlineAudioFallback = false
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        XCTAssertNil(settings.conversionOptions.ttsPreferences?.secondary)
    }

    func testSecondaryAudioEngineCannotDuplicatePrimary() {
        let (settings, defaults) = make()
        settings.allowOnlineAudioFallback = true

        settings.secondaryAudioEngine = .piper
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))

        settings.audioEngine = .edge
        settings.secondaryAudioEngine = .edge
        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
    }

    func testLegacyUnconsentedEdgeSecondaryIsMigratedOnLoad() {
        let suite = "Toolbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("edge", forKey: "secondaryAudioEngine")
        defaults.set(false, forKey: "allowOnlineAudioFallback")

        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(settings.secondaryAudioEngine)
        XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        XCTAssertNil(settings.ttsPreferences.secondary)
        defaults.removePersistentDomain(forName: suite)
    }

    func testEdgePrimaryRemainsAvailableWithoutFallbackConsent() throws {
        let (settings, _) = make()
        settings.audioEngine = .edge

        XCTAssertEqual(settings.audioEngine, .edge)
        XCTAssertFalse(settings.allowOnlineAudioFallback)
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertEqual(settings.conversionOptions.ttsPreferences?.primary.engine, "edge")
        XCTAssertEqual(settings.conversionOptions.ttsPreferences?.allowOnlineFallback, false)
    }

    @MainActor
    func testManualEdgePrimaryWithoutConsentKeepsSavedPreferences() async throws {
        let (settings, _) = make()
        let originalPreferences = settings.ttsPreferences
        var captured: ConversionOptions?
        let model = ConvertViewModel(converter: { _, _, _, options in
            captured = options
            return .init(jobID: "manual-edge-primary", manifestJSON: Data(),
                         outputDirectory: URL(fileURLWithPath: "/unused-fixture"))
        })
        model.selectedFile = URL(fileURLWithPath: "/unused-fixture.epub")
        model.engine = "edge"
        model.voice = "pt-BR-AntonioNeural"
        model.usesPreferences = false
        model.allowSecondary = false

        await model.submit()

        XCTAssertEqual(captured?.ttsPreferences?.primary.engine, "edge")
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, false)
        XCTAssertEqual(settings.ttsPreferences, originalPreferences)
    }

    func testFaberDefaultsAndExplicitEdgeChoicePersist() throws {
        let (settings, defaults) = make()
        XCTAssertEqual(settings.audioEngine, .piper)
        XCTAssertEqual(settings.ttsPreferences.secondary?.engine, "system")
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
        XCTAssertFalse(settings.ttsPreferences.allowOnlineFallback)
        settings.audioEngine = .edge
        settings.secondaryAudioEngine = .piper
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.audioEngine, .edge)
        XCTAssertEqual(restored.secondaryAudioEngine, .piper)
        let captured = restored.conversionOptions
        restored.audioEngine = .piper
        XCTAssertEqual(captured.ttsPreferences?.primary.engine, "edge")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captured.encodedJSON().utf8)) as? [String: Any])
        let policy = try XCTUnwrap(fields["tts_preferences"] as? [String: Any])
        XCTAssertEqual(policy["allow_online_fallback"] as? Bool, false)
        XCTAssertEqual((policy["secondary"] as? [String: Any])?["model_id"] as? String, "pt_BR-faber-medium")
    }

    @MainActor
    func testManualOverrideIsStrictAndDoesNotChangePreferences() async throws {
        let (settings, _) = make()
        settings.allowOnlineAudioFallback = true
        settings.secondaryAudioEngine = .edge
        var captured: ConversionOptions?
        let model = ConvertViewModel(converter: { _, _, _, options in
            captured = options
            return .init(jobID: "manual-fixture", manifestJSON: Data(),
                         outputDirectory: URL(fileURLWithPath: "/unused-fixture"))
        })
        model.selectedFile = URL(fileURLWithPath: "/unused-fixture.epub")
        model.inheritedPreferences = settings.ttsPreferences
        model.engine = "piper"
        model.usesPreferences = false
        await model.submit()
        XCTAssertEqual(model.submittedJobId, "manual-fixture")
        XCTAssertEqual(captured?.ttsPreferences?.primary.modelID, "pt_BR-faber-medium")
        XCTAssertNil(captured?.ttsPreferences?.secondary)
        XCTAssertEqual(captured?.ttsPreferences?.allowOnlineFallback, false)
        XCTAssertEqual(settings.secondaryAudioEngine, .edge)
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
        XCTAssertEqual(settings.audioEngine, .piper)
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
        s.backendURL = "http://my-backend"
        s.readerOverrideFontFamily = true
        s.restoreOriginal()
        XCTAssertEqual(s.readerLayout, .paginated)
        XCTAssertEqual(s.readerTheme, .sepia)
        XCTAssertFalse(s.readerAutoScroll)
        XCTAssertEqual(s.backendURL, "http://my-backend")
        XCTAssertFalse(s.readerOverrideFontFamily)
    }
}
