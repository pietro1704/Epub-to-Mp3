#if os(iOS)
import XCTest
import UIKit
@testable import EpubToMp3

@MainActor
final class TtsMissingVoiceRecoveryTests: XCTestCase {
    func testMissingVoiceAlertExposesAllThreeActionsAndCancellation() throws {
        let snapshot = try makeSnapshot()
        let recommended = try XCTUnwrap(TtsMissingVoicePolicy.recommended(in: snapshot))
        let alert = TtsMissingVoiceAlert.makeAlert(language: "en-US", recommended: recommended,
                                                  systemAvailable: true) { _ in }
        XCTAssertEqual(alert.actions.map(\.title), [
            L10n.string("tts.missingVoice.downloadRecommended"), L10n.string("tts.missingVoice.openSettings"),
            L10n.string("tts.missingVoice.system"), L10n.string("common.cancel")])
        XCTAssertTrue(alert.actions.allSatisfy(\.isEnabled))
        XCTAssertTrue(alert.preferredAction === alert.actions[0])
        XCTAssertEqual(alert.actions.last?.style, .cancel)
        XCTAssertTrue(alert.message?.contains("Fixture English") == true)
        let unavailable = TtsMissingVoiceAlert.makeAlert(language: "xx", recommended: nil,
                                                        systemAvailable: false) { _ in }
        XCTAssertFalse(unavailable.actions[0].isEnabled)
        XCTAssertTrue(unavailable.actions[1].isEnabled)
        XCTAssertFalse(unavailable.actions[2].isEnabled)
    }

    func testRecommendationNeverOffersInstalledIncompatibleOrOnlineModels() throws {
        for (installed, compatible, provider) in [(true, true, "piper"), (false, false, "piper"), (false, true, "edge")] {
            XCTAssertNil(TtsMissingVoicePolicy.recommended(in:
                try makeSnapshot(installed: installed, compatible: compatible, provider: provider)))
        }
        XCTAssertNil(TtsMissingVoicePolicy.recommended(in: try makeSnapshot(licenceValidation: "rejected")))
        XCTAssertEqual(TtsMissingVoicePolicy.recommended(in: try makeSnapshot())?.identity.modelID, "fixture-english")
    }

    func testConfirmedDownloadUsesBookLanguageWithoutChangingStudyLanguageOrPrimary() async throws {
        let suite = "missing-voice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pt-BR", forKey: SpeechModelLibraryTarget.studyLanguageDefaultsKey)
        let settings = AppSettings(defaults: defaults)
        let original = settings.ttsPreferences
        let snapshot = try makeSnapshot()
        let calls = InstallCalls()
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot, installAsync: { id, root in
            await calls.record(id)
            return URL(fileURLWithPath: root).appendingPathComponent(id)
        }, languageDefaults: defaults)
        _ = try await client.install(modelID: "fixture-english", language: "en-US")
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["fixture-english"])
        XCTAssertEqual(defaults.string(forKey: SpeechModelLibraryTarget.studyLanguageDefaultsKey), "pt-BR")
        XCTAssertEqual(settings.ttsPreferences, original)
        do {
            _ = try await client.install(modelID: "fixture-english", language: "fr-FR")
            XCTFail("Mismatched language must fail before starting a download")
        } catch { }
        let unchanged = await calls.values
        XCTAssertEqual(unchanged, recorded)
    }

    func testDownloadFailureAndCancellationNeverBecomeAPlayableSelection() async throws {
        for cancelled in [false, true] {
            let snapshot = try makeSnapshot()
            let client = SpeechModelLibraryClient(initialSnapshot: snapshot, installAsync: { _, _ in
                if cancelled { throw CancellationError() }
                throw CocoaError(.fileWriteOutOfSpace)
            })
            do {
                _ = try await client.install(modelID: "fixture-english", language: "en-US")
                XCTFail("The installation error must propagate")
            } catch {
                XCTAssertEqual(error is CancellationError, cancelled)
            }
            let retained = try await client.recoverySnapshot(language: "en-US")
            XCTAssertTrue(TtsRecoveryCandidate.available(in: retained, excluding: "").isEmpty)
        }
    }

    func testSystemRecoveryServesOneRequestAsSecondaryVoiceWithoutChangingTheBookLanguage() async throws {
        var original = ConversionOptions(engine: "piper", language: "en-US")
        original.ttsPreferences = TtsPreferences(primary: .defaultPiper, secondary: nil,
                                                 allowOnlineFallback: false, policyVersion: 2)
        let system = TtsRecoveryCandidate(name: "Installed system voice", selection: .systemDefault)
        let recovered = original.recovering(with: system, language: "pt-BR")
        XCTAssertEqual(recovered.engine, "piper")
        XCTAssertEqual(recovered.language, "en-US", "Recovery never rewrites the book language")
        XCTAssertEqual(recovered.ttsPreferences?.primary.engine, "piper")
        XCTAssertEqual(recovered.ttsPreferences?.secondary?.engine, "system")
        XCTAssertEqual(recovered.ttsPreferences?.policyVersion, 3)
        XCTAssertEqual(recovered.ttsPreferences?.allowOnlineFallback, false)
        XCTAssertNil(original.ttsPreferences?.secondary)
        XCTAssertEqual(original.ttsPreferences?.policyVersion, 2)

        // The explicit choice satisfies the listening preflight, so the alert is not repeated.
        let client = SpeechModelLibraryClient(initialSnapshot: try makeSnapshot())
        let english = [InstalledSpeechVoicePolicy.Voice(identifier: "fixture.en", name: "Fixture",
                                                       language: "en-US", isCompact: false)]
        try await TtsMissingVoicePreflight.validate(options: recovered, client: client, systemVoices: { english })
        for (options, voices) in [(original, english), (recovered, [])] {
            do {
                try await TtsMissingVoicePreflight.validate(options: options, client: client, systemVoices: { voices })
                XCTFail("Automatic fallback and a missing system voice must still ask first")
            } catch {
                XCTAssertEqual(TtsLanguageMismatch.decode(error)?.language, "en-US")
            }
        }
    }

    func testListeningPreflightAsksOnlyForAnAuthoritativeLanguageWithoutAnInstalledVoice() async throws {
        let client = SpeechModelLibraryClient(initialSnapshot: try makeSnapshot())
        do {
            try await TtsMissingVoicePreflight.validate(
                options: ConversionOptions(engine: "piper", language: "en-US", modelID: "pt_BR-faber-medium"),
                client: client, systemVoices: { [] })
            XCTFail("Missing local voices must reach the actionable alert instead of silent fallback")
        } catch {
            XCTAssertEqual(TtsLanguageMismatch.decode(error), .init(language: "en-US", modelID: "pt_BR-faber-medium"))
        }
        // Declared metadata is only a hint: without an authoritative language Rust resolves it.
        try await TtsMissingVoicePreflight.validate(options: ConversionOptions(engine: "piper"), client: client)
        try await TtsMissingVoicePreflight.validate(options: ConversionOptions(engine: "piper", language: "  "), client: client)
        // A catalogue that answers for another language is not evidence of a missing voice.
        try await TtsMissingVoicePreflight.validate(
            options: ConversionOptions(engine: "piper", language: "fr-FR"), client: client)
        let ready = SpeechModelLibraryClient(initialSnapshot: try makeSnapshot(installed: true, ready: true))
        try await TtsMissingVoicePreflight.validate(
            options: ConversionOptions(engine: "piper", language: "en-US"), client: ready)
        try await TtsMissingVoicePreflight.validate(
            options: ConversionOptions(engine: "system", language: "en-US"), client: client)
    }

    func testLanguageActionPresentsTheVoiceModelDestinationOverACoveringReader() async throws {
        let suite = "missing-voice-navigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let snapshot = try makeSnapshot()
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let settings = SettingsScreenController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, importDirectory: root), player: player,
            playbackClock: PlaybackClock(), speechModels: client)
        let settingsNavigation = UINavigationController(rootViewController: settings)
        let tabs = UITabBarController()
        tabs.viewControllers = [UINavigationController(rootViewController: UIViewController()), settingsNavigation]
        // Like the app's root container, the reader is a sibling that covers the tab shell.
        let container = UIViewController()
        let reader = UIViewController()
        for child in [tabs, reader] {
            container.addChild(child)
            container.view.addSubview(child.view)
            child.didMove(toParent: container)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await TtsMissingVoiceAlert.openSettings(language: "en-US", snapshot: snapshot, from: container, client: client)
        let sheet = try XCTUnwrap(container.presentedViewController as? UINavigationController,
                                  "The destination must be visible above the reader")
        let destination = try XCTUnwrap(sheet.topViewController as? ModelsScreenController,
                                        "The missing-voice alert leads to the Models screen")
        XCTAssertEqual(destination.title, L10n.string("models.title"))
        XCTAssertNotNil(destination.navigationItem.rightBarButtonItem, "The sheet needs its own way back to the book")
        XCTAssertTrue(tabs.selectedViewController !== settingsNavigation, "The covered tab shell is left alone")
        XCTAssertTrue(settingsNavigation.topViewController === settings)
        XCTAssertNil(settings.modelEntry(at: IndexPath(row: 0, section: 1)), "Settings never expands inline")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "missing-voice-language-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStaleBookRequestDoesNotPresentAnAlertOrDownload() async throws {
        let calls = InstallCalls()
        let client = SpeechModelLibraryClient(initialSnapshot: try makeSnapshot(), installAsync: { id, root in
            await calls.record(id)
            return URL(fileURLWithPath: root).appendingPathComponent(id)
        })
        let controller = UIViewController()
        let choice = await TtsMissingVoiceAlert.choose(language: "en-US", on: controller,
                                                       client: client, isCurrent: { false })
        XCTAssertNil(choice)
        XCTAssertNil(controller.presentedViewController)
        let downloaded = await calls.values
        XCTAssertTrue(downloaded.isEmpty)
    }

    private actor InstallCalls {
        var values: [String] = []
        func record(_ id: String) { values.append(id) }
    }

    private func makeSnapshot(installed: Bool = false, compatible: Bool = true, ready: Bool = false,
                              provider: String = "piper", licenceValidation: String = "unknown") throws -> SpeechModelSnapshot {
        let document: [String: Any] = [
            "schema_version": 3, "generated_from_catalog_revision": "fixture",
            "target": ["language": "en-US"],
            "default_selection": ["version": 2, "provider": "piper", "runtime": "piper", "model_id": "fixture-english", "options": [String: String]()],
            "entries": [[
                "identity": ["provider": provider, "runtime": provider, "model_id": "fixture-english", "model_revision": "fixture"],
                "presentation": ["model_name": "Fixture English", "family_name": "Fixture", "quality": "medium", "voice_choices": []],
                "language_evidence": ["routing_tags": ["en"], "exact_tags": [["tag": "en-US", "validation": "artifact_declared"]]],
                "distribution": ["installable": true, "download_bytes": 100],
                "licence": ["category": "unknown", "requires_acceptance": false, "validation": licenceValidation],
                "compatibility": ["compatible": compatible, "reasons": compatible ? [] : ["unsupported_language"]],
                "installation": ["state": installed ? "installed" : "missing"],
                "readiness": ["state": ready ? "ready" : "not_inspected"],
                "selection": ["selectable": ready && installed, "reasons": ready && installed ? [] : ["installation_missing"]]
            ]]
        ]
        return try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
    }
}
#endif
