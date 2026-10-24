import XCTest
@testable import EpubToMp3

final class TtsCatalogTests: XCTestCase {
    func testDescriptorSelectionPreservesRuntimeModelRevisionAndVoiceAcrossSnapshot() throws {
        let json = Data("""
        {"version":2,"models":[{"id":"model-a","engine":"provider-a","runtime":"runtime-a",
        "revision":"sha-a","languages":["pt"],"platforms":["Macos"]},
        {"id":"model-b","engine":"provider-a","runtime":"runtime-a",
        "revision":"sha-b","languages":["en"],"platforms":["Macos"]}]}
        """.utf8)
        let catalog = try TtsCatalog.decode(json)
        let first = try XCTUnwrap(catalog.models[0].selection(voice: "voice-a"))
        let second = try XCTUnwrap(catalog.models[1].selection(voice: "voice-b"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.session?.runtime, "runtime-a")
        XCTAssertEqual(second.session?.modelRevision, "sha-b")
        XCTAssertEqual(try JSONDecoder().decode(TtsSelection.self, from: JSONEncoder().encode(first)), first)
        let legacy = try JSONDecoder().decode(TtsSelection.self, from: Data("{\"engine\":\"system\"}".utf8))
        XCTAssertNil(legacy.session)
    }

    func testUnsupportedCatalogAndUnavailableAdapterFailExplicitly() throws {
        XCTAssertThrowsError(try TtsCatalog.decode(Data("{\"version\":3,\"models\":[]}".utf8)))
        XCTAssertThrowsError(try ConverterModelCatalog().ttsCatalog())
    }

    func testVersionedPrimaryKeepsLegacyFallbackAndRequiresTheVersionedBinding() throws {
        let primary = TtsSelection(engine: "piper", modelID: "model-a", voice: nil,
            session: TtsSessionSelection(provider: "piper", runtime: "piper", modelID: "model-a", modelRevision: "sha-a", voice: nil))
        var options = ConversionOptions()
        options.ttsPreferences = TtsPreferences(primary: primary, secondary: .selected(.system), allowOnlineFallback: false, policyVersion: 2)
        XCTAssertTrue(options.requiresSessionABI)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(options.encodedJSON().utf8)) as? [String: Any])
        XCTAssertEqual(fields["contract_version"] as? Int, 2)
        XCTAssertTrue(primary.representsSameRequest(as: TtsSelection(engine: "piper", modelID: "model-a", voice: nil)))
    }

    func testRevokingOnlineConsentClearsACapturedSecondary() throws {
        let suite = "TtsCatalogConsent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        settings.selectSecondaryNarration(.selected(.edge))
        settings.allowOnlineAudioFallback = false
        XCTAssertNil(settings.ttsPreferences.secondary)
        XCTAssertNil(AppSettings(defaults: defaults).ttsPreferences.secondary)
    }

    func testSelectedDescriptorPersistsAndCapturedJobsKeepTheirOriginalSelection() throws {
        let suite = "TtsCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let first = TtsSelection(engine: "piper", modelID: "model-a", voice: nil,
            session: TtsSessionSelection(provider: "piper", runtime: "runtime-a", modelID: "model-a", modelRevision: "sha-a", voice: nil))
        settings.selectPrimaryNarration(first)
        let captured = settings.ttsPreferences
        let second = TtsSelection(engine: "piper", modelID: "model-b", voice: nil,
            session: TtsSessionSelection(provider: "piper", runtime: "runtime-a", modelID: "model-b", modelRevision: "sha-b", voice: nil))
        settings.selectPrimaryNarration(second)
        XCTAssertEqual(captured.primary, first)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.primary, second)
        settings.audioEngine = .system
        XCTAssertNil(settings.primaryTtsSelection)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.primary.engine, "system")
    }
}
