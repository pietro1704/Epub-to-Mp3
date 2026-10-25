#if os(iOS) || os(macOS)
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

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
        XCTAssertEqual(try JSONEncoder().encode(originalChoice.selection),
                       try JSONEncoder().encode(renamedChoice.selection))
    }

    func testV3DecoderFailsClosedForUnknownVersionAndMalformedIdentity() throws {
        XCTAssertThrowsError(try SpeechModelSnapshot.decode(snapshotJSON(schemaVersion: 4)))
        let malformed = snapshotJSON().dropLast()
        XCTAssertThrowsError(try SpeechModelSnapshot.decode(Data(malformed)))
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
    }

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
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == expected })
        XCTAssertFalse(expected.contains("pt_BR-faber-medium"))
        #endif
    }

    private func snapshotJSON(
        schemaVersion: Int = 3,
        modelName: String = "Faber",
        installable: Bool = true,
        installationState: String = "installed",
        readinessState: String = "ready",
        selectable: Bool = true
    ) -> Data {
        Data("""
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

    #if os(macOS)
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    #endif
}
#endif
