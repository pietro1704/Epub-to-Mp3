#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelLibraryClientTests: XCTestCase {
    func testV3PresentationCanChangeWithoutChangingLiteralSelectionIdentity() throws {
        let original = try SpeechModelSnapshot.decode(snapshotJSON(modelName: "Faber"))
        let renamed = try SpeechModelSnapshot.decode(snapshotJSON(modelName: "Faber Narrator"))
        let originalState = SpeechModelLibraryViewState(snapshot: original)
        let renamedState = SpeechModelLibraryViewState(snapshot: renamed)
        let originalChoice = try XCTUnwrap(originalState.selectableChoices.first)
        let renamedChoice = try XCTUnwrap(renamedState.selectableChoices.first)

        XCTAssertNotEqual(originalChoice.title, renamedChoice.title)
        XCTAssertEqual(originalChoice.selection, renamedChoice.selection)
        XCTAssertEqual(originalChoice.selection.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(originalChoice.selection.session?.modelRevision, "model-revision")
        XCTAssertNil(originalChoice.selection.voice)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(originalChoice.selection),
                       try encoder.encode(renamedChoice.selection))
    }

    func testV3DecoderFailsClosedForUnknownVersionAndMalformedIdentity() throws {
        XCTAssertThrowsError(try SpeechModelSnapshot.decode(snapshotJSON(schemaVersion: 4)))
        let malformed = snapshotJSON().dropLast()
        XCTAssertThrowsError(try SpeechModelSnapshot.decode(Data(malformed)))
    }

    func testNewHighQualityVoiceKeepsLiteralIdentityAndCreatorLicenceEvidence() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotJSON()) as? [String: Any])
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        var identity = try XCTUnwrap(entries[0]["identity"] as? [String: Any])
        identity["model_id"] = "en_US-ljspeech-high"
        entries[0]["identity"] = identity
        entries[0]["presentation"] = [
            "model_name": "LJ Speech", "family_name": "Piper", "quality": "high",
            "voice_choices": [["voice_id": NSNull(), "name": "LJ Speech"]],
        ]
        entries[0]["language_evidence"] = [
            "routing_tags": ["en"],
            "exact_tags": [["tag": "en-US", "frontend": "espeak-ng:en", "validation": "artifact_declared"]],
        ]
        entries[0]["licence"] = [
            "id": "LicenseRef-Public-Domain", "category": "model_weights",
            "evidence_url": "https://brycebeattie.com/files/tts/",
            "requires_acceptance": false, "validation": "creator_declared",
        ]
        document["entries"] = entries
        let snapshot = try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertTrue(state.displayName(for: entry).contains(L10n.string("settings.modelQuality.high")))
        XCTAssertEqual(state.selection(for: entry)?.modelID, "en_US-ljspeech-high")
        XCTAssertNil(state.selection(for: entry)?.voice)
        XCTAssertTrue(state.details(for: entry).contains(
            L10n.string("settings.modelLicence.creatorDeclared", "LicenseRef-Public-Domain")
        ))
        XCTAssertTrue(state.details(for: entry).contains(L10n.string("settings.modelPerformance.unmeasured")))
    }

    func testNonInstallableEntryIsVisibleButNeverBecomesAnAction() throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON(
            installable: false,
            installationState: "not_applicable",
            readinessState: "not_applicable",
            selectable: false
        ))
        let state = SpeechModelLibraryViewState(snapshot: snapshot)

        XCTAssertNotNil(state.defaultEntry)
        XCTAssertTrue(state.selectableChoices.isEmpty)
        XCTAssertEqual(state.defaultEntry.map(state.status(for:)),
                       L10n.string("settings.modelState.notInstallable"))
        let entry = try XCTUnwrap(state.defaultEntry)
        XCTAssertTrue(state.actions(
            for: entry,
            configuredSelections: [],
            installEvent: nil,
            termsAccepted: false
        ).available.isEmpty)
    }

    func testConfiguredModelCannotBeSelectedAgainWithoutReadinessOrWithStaleRevision() throws {
        let unavailable = SpeechModelLibraryViewState(snapshot: try SpeechModelSnapshot.decode(snapshotJSON(
            installationState: "missing", readinessState: "not_inspected", selectable: false
        )))
        XCTAssertFalse(unavailable.canSelect(.selected(.piper)))
        let ready = SpeechModelLibraryViewState(snapshot: try SpeechModelSnapshot.decode(snapshotJSON()))
        XCTAssertTrue(ready.canSelect(.selected(.piper)))
        var stale = try XCTUnwrap(ready.selectableChoices.first?.selection)
        stale.session?.modelRevision = "stale-revision"
        XCTAssertFalse(ready.canSelect(stale))
    }

    func testCatalogueDetailsExposeEvidenceWithoutInventingSpeed() throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON())
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let details = state.details(for: try XCTUnwrap(snapshot.entries.first))

        XCTAssertTrue(details.contains(ByteCountFormatter.string(
            fromByteCount: 63_206_149, countStyle: .file
        )))
        XCTAssertTrue(details.contains("CC0-1.0"))
        XCTAssertTrue(details.contains(L10n.string("settings.modelLanguage.runtimeValidated")))
        XCTAssertTrue(details.contains(L10n.string("settings.modelPerformance.unmeasured")))
        XCTAssertFalse(details.contains("pt_BR-faber-medium"))
    }

    func testProductActionsDistinguishSelectionRemovalAndActiveInstallation() throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON())
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let entry = try XCTUnwrap(snapshot.entries.first)
        let selection = try XCTUnwrap(state.selection(for: entry))

        let available = state.actions(
            for: entry,
            configuredSelections: [],
            installEvent: nil,
            termsAccepted: false
        )
        XCTAssertEqual(available.available, [.preview, .select, .remove])
        XCTAssertNil(available.removalBlock)

        let configured = state.actions(
            for: entry,
            configuredSelections: [selection],
            installEvent: nil,
            termsAccepted: false
        )
        XCTAssertEqual(configured.available, [.preview])
        XCTAssertEqual(configured.removalBlock, .configured("pt_BR-faber-medium"))

        let active = state.actions(
            for: entry,
            configuredSelections: [],
            installEvent: installEvent(stage: .downloading),
            termsAccepted: false
        )
        XCTAssertEqual(active.available, [.cancelInstall])
        XCTAssertEqual(active.removalBlock, .inUse("pt_BR-faber-medium"))
    }

    func testInstallAndSelectionAreIndependentAndRemovalProtectsConfiguredIdentity() async throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON())
        let recorder = ModelActionRecorder()
        let client = SpeechModelLibraryClient(
            initialSnapshot: snapshot,
            install: { modelID, root in
                recorder.recordInstall(modelID: modelID, root: root)
                return URL(fileURLWithPath: root).appendingPathComponent(modelID)
            },
            remove: { modelID, root in recorder.recordRemoval(modelID: modelID, root: root) }
        )
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let selection = try XCTUnwrap(state.selectableChoices.first?.selection)
        var configuredSelection = TtsSelection.selected(.system)

        _ = try await client.install(modelID: selection.modelID!)
        XCTAssertEqual(configuredSelection.engine, "system")
        XCTAssertEqual(recorder.installs.map(\.modelID), ["pt_BR-faber-medium"])

        configuredSelection = selection
        XCTAssertEqual(recorder.installs.count, 1, "Selecting must not start another install")
        do {
            _ = try await client.remove(
                modelID: "pt_BR-faber-medium",
                configuredSelections: [configuredSelection]
            )
            XCTFail("Expected configured-model removal to fail")
        } catch let error as SpeechModelRemovalError {
            XCTAssertEqual(error, .configured("pt_BR-faber-medium"))
        }
        XCTAssertTrue(recorder.removals.isEmpty)

        configuredSelection = .selected(.system)
        _ = try await client.remove(
            modelID: "pt_BR-faber-medium",
            configuredSelections: [configuredSelection]
        )
        XCTAssertEqual(recorder.removals.map(\.modelID), ["pt_BR-faber-medium"])
        XCTAssertEqual(recorder.installs.count, 1)
    }

    func testTermsRevocationChangesConsentOnlyAndPreservesInstalledFiles() throws {
        let suite = "SpeechModelTerms.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechModelTermsAcceptanceStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terms-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("model.onnx")
        try Data("verified".utf8).write(to: artifact)

        store.accept(modelID: "model-a", fingerprint: "terms-v1")
        XCTAssertTrue(store.isAccepted(modelID: "model-a", fingerprint: "terms-v1"))
        store.revoke(modelID: "model-a", fingerprint: "terms-v1")

        XCTAssertFalse(store.isAccepted(modelID: "model-a", fingerprint: "terms-v1"))
        XCTAssertEqual(try Data(contentsOf: artifact), Data("verified".utf8))
    }

    func testRequiredTermsFingerprintFailsClosedBeforeInstallerRuns() async throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON(
            installationState: "missing",
            readinessState: "not_inspected",
            selectable: false,
            requiresAcceptance: true,
            termsFingerprint: "terms-v1"
        ))
        let recorder = ModelActionRecorder()
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot, install: { modelID, root in
            recorder.recordInstall(modelID: modelID, root: root)
            return URL(fileURLWithPath: root).appendingPathComponent(modelID)
        })

        let rejectedFingerprints: [String?] = [nil, "", "terms-for-another-revision"]
        for fingerprint in rejectedFingerprints {
            do {
                _ = try await client.install(
                    modelID: "pt_BR-faber-medium", acceptedTermsFingerprint: fingerprint
                )
                XCTFail("Only the exact terms fingerprint can authorize installation")
            } catch let error as SpeechModelInstallationError {
                XCTAssertEqual(error, .termsAcceptanceRequired("pt_BR-faber-medium"))
            }
        }
        XCTAssertTrue(recorder.installs.isEmpty)

        _ = try await client.install(
            modelID: "pt_BR-faber-medium",
            acceptedTermsFingerprint: "terms-v1"
        )
        XCTAssertEqual(recorder.installs.map(\.modelID), ["pt_BR-faber-medium"])
    }

    func testRequiredTermsWithMissingFingerprintRejectsMalformedMetadata() async throws {
        let missingFingerprints: [String?] = [nil, ""]
        for fingerprint in missingFingerprints {
            let snapshot = try SpeechModelSnapshot.decode(snapshotJSON(
                requiresAcceptance: true, termsFingerprint: fingerprint
            ))
            let recorder = ModelActionRecorder()
            let client = SpeechModelLibraryClient(initialSnapshot: snapshot, install: { modelID, root in
                recorder.recordInstall(modelID: modelID, root: root)
                return URL(fileURLWithPath: root).appendingPathComponent(modelID)
            })
            do {
                _ = try await client.install(
                    modelID: "pt_BR-faber-medium", acceptedTermsFingerprint: fingerprint
                )
                XCTFail("Missing/empty metadata must not count as matching consent")
            } catch let error as SpeechModelInstallationError {
                XCTAssertEqual(error, .termsAcceptanceRequired("pt_BR-faber-medium"))
            }
            XCTAssertTrue(recorder.installs.isEmpty)
        }
    }

    #if !SWIFT_PACKAGE
    func testRefreshFailureKeepsExistingPreferenceAndLastValidSnapshot() async throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON())
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot, loadSnapshot: {
            throw EmbeddedConverterError.artifactUnavailable
        })
        let suite = "SpeechModelLibraryClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let selected = try XCTUnwrap(SpeechModelLibraryViewState(snapshot: snapshot)
            .selectableChoices.first?.selection)
        settings.selectPrimaryNarration(selected)

        do {
            _ = try await client.snapshot()
            XCTFail("Expected the injected refresh failure")
        } catch {
            XCTAssertEqual(error as? EmbeddedConverterError, .artifactUnavailable)
        }

        XCTAssertEqual(settings.ttsPreferences.primary, selected)
        XCTAssertEqual(client.initialSnapshot?.generatedFromCatalogRevision, "catalog-revision")
    }

    @MainActor
    func testNativeSettingsUsesTheSameHumanV3LabelWithoutShowingModelID() throws {
        let snapshot = try SpeechModelSnapshot.decode(snapshotJSON())
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot)
        let expected = SpeechModelLibraryViewState(snapshot: snapshot)
            .displayName(for: try XCTUnwrap(snapshot.entries.first))
        let suite = "SpeechModelLibrarySettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        #if os(iOS)
        let player = AudioPlayer()
        defer { player.stop() }
        let controller = SettingsScreenController(
            settings: settings,
            library: LibraryStore(defaults: defaults),
            player: player,
            playbackClock: PlaybackClock(),
            speechModels: client
        )
        controller.loadViewIfNeeded()
        let primary = controller.tableView(controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0))
        let model = controller.tableView(controller.tableView,
            cellForRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual((primary.contentConfiguration as? UIListContentConfiguration)?.secondaryText, expected)
        XCTAssertEqual((model.contentConfiguration as? UIListContentConfiguration)?.text, expected)
        XCTAssertFalse(expected.contains("pt_BR-faber-medium"))
        #else
        let controller = MacSettingsViewController(
            settings: settings,
            library: LibraryStore(defaults: defaults),
            speechModels: client
        )
        controller.loadViewIfNeeded()
        let controls = descendants(controller.view)
        let primary = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "settings.tts.primary" })
        XCTAssertEqual(primary.titleOfSelectedItem, expected)
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.components(separatedBy: "\n").first == expected
        })
        XCTAssertFalse(expected.contains("pt_BR-faber-medium"))
        #endif
    }
    #endif

    private func snapshotJSON(
        schemaVersion: Int = 3,
        modelName: String = "Faber",
        installable: Bool = true,
        installationState: String = "installed",
        readinessState: String = "ready",
        selectable: Bool = true,
        requiresAcceptance: Bool = false,
        termsFingerprint: String? = nil
    ) -> Data {
        let fingerprintJSON = termsFingerprint.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "schema_version": \(schemaVersion),
          "generated_from_catalog_revision": "catalog-revision",
          "default_selection": {
            "version": 2,
            "provider": "piper",
            "runtime": "piper",
            "model_id": "pt_BR-faber-medium",
            "model_revision": "model-revision",
            "voice": null,
            "options": {}
          },
          "entries": [{
            "identity": {
              "provider": "piper",
              "runtime": "piper",
              "model_id": "pt_BR-faber-medium",
              "model_revision": "model-revision"
            },
            "presentation": {
              "model_name": "\(modelName)",
              "family_name": "Piper",
              "quality": "medium",
              "voice_choices": [{"voice_id": null, "name": "Faber"}]
            },
            "language_evidence": {
              "routing_tags": ["pt"],
              "exact_tags": [{
                "tag": "pt-BR",
                "frontend": "espeak-ng:pt-br",
                "validation": "runtime_validated"
              }]
            },
            "distribution": {
              "installable": \(installable),
              "download_bytes": 63206149,
              "installed_bytes": 63206149
            },
            "licence": {
              "id": "CC0-1.0",
              "category": "dataset",
              "evidence_url": "https://example.invalid/model-card",
              "terms_fingerprint": \(fingerprintJSON),
              "requires_acceptance": \(requiresAcceptance),
              "validation": "partial"
            },
            "compatibility": {"compatible": true, "reasons": []},
            "installation": {
              "state": "\(installationState)",
              "verified_revision": "model-revision",
              "installed_bytes": 63206149
            },
            "readiness": {
              "state": "\(readinessState)",
              "active_runtime_revision": "embedded-piper-v1",
              "failure": null
            },
            "selection": {"selectable": \(selectable), "reasons": []}
          }]
        }
        """.utf8)
    }

    private func installEvent(stage: SpeechModelInstallEvent.Stage) -> SpeechModelInstallEvent {
        SpeechModelInstallEvent(
            sequence: 1,
            operationID: "operation-id",
            modelID: "pt_BR-faber-medium",
            stage: stage,
            artifactIndex: 0,
            bytesCompleted: 1,
            bytesTotal: 2,
            failure: nil
        )
    }

    #if os(macOS)
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #endif
}

private final class ModelActionRecorder: @unchecked Sendable {
    struct Call {
        let modelID: String
        let root: String
    }

    private let lock = NSLock()
    private var recordedInstalls: [Call] = []
    private var recordedRemovals: [Call] = []

    var installs: [Call] { lock.withLock { recordedInstalls } }
    var removals: [Call] { lock.withLock { recordedRemovals } }

    func recordInstall(modelID: String, root: String) {
        lock.withLock { recordedInstalls.append(Call(modelID: modelID, root: root)) }
    }

    func recordRemoval(modelID: String, root: String) {
        lock.withLock { recordedRemovals.append(Call(modelID: modelID, root: root)) }
    }
}
#endif
