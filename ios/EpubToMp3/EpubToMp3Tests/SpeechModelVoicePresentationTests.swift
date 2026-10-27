import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelVoicePresentationTests: XCTestCase {
    func testActualPiperFallbackUsesItsOwnCatalogueVoiceInsteadOfFaber() throws {
        let store = SpeechModelPresentationStore()
        store.update(try snapshot(caduName: "Cadu"))
        let rendered = try XCTUnwrap(store.displayName(
            engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil
        ))
        XCTAssertTrue(rendered.contains("Cadu"))
        XCTAssertFalse(rendered.contains("Faber"))
        XCTAssertFalse(rendered.contains("pt_BR-cadu-medium"))

        store.update(try snapshot(caduName: "Updated Cadu label"))
        XCTAssertTrue(try XCTUnwrap(store.displayName(
            engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil
        )).contains("Updated Cadu label"))
    }

    func testSystemFallbackAndPrimaryRecoveryKeepDifferentActualVoices() throws {
        let store = SpeechModelPresentationStore()
        store.update(try snapshot(caduName: "Cadu"))
        XCTAssertEqual(store.displayName(
            engine: "system", modelID: nil, voice: "Luciana (installed.luciana)"
        ), "Luciana")
        let recovered = try XCTUnwrap(store.displayName(
            engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil
        ))
        XCTAssertTrue(recovered.contains("Cadu"))
        XCTAssertFalse(recovered.contains("Luciana"))
        let mixed = store.activeVoices("pt_BR-cadu-medium + Luciana (installed.luciana)", engine: nil)
        XCTAssertTrue(mixed.contains("Cadu"))
        XCTAssertTrue(mixed.contains("Luciana"))
        XCTAssertFalse(mixed.contains("pt_BR-cadu-medium"))
        XCTAssertFalse(mixed.contains("installed.luciana"))
    }

    func testColdCatalogueCacheDoesNotInventAFaberSelection() {
        let store = SpeechModelPresentationStore()
        XCTAssertEqual(store.displayName(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil), "Piper")
        XCTAssertNil(store.displayName(engine: nil, modelID: nil, voice: nil))
    }

    private func snapshot(caduName: String) throws -> SpeechModelSnapshot {
        let entries: [[String: Any]] = [("pt_BR-faber-medium", "Faber"), ("pt_BR-cadu-medium", caduName)].map { id, name in
            [
                "identity": ["provider": "piper", "runtime": "piper", "model_id": id, "model_revision": "fixture"],
                "presentation": ["model_name": name, "family_name": "Piper", "quality": "medium", "voice_choices": []],
                "language_evidence": ["routing_tags": ["pt"], "exact_tags": [["tag": "pt-BR", "validation": "artifact_declared"]]],
                "distribution": ["installable": true],
                "licence": ["category": "unknown", "requires_acceptance": false, "validation": "unknown"],
                "compatibility": ["compatible": true, "reasons": []],
                "installation": ["state": "missing"], "readiness": ["state": "not_inspected"],
                "selection": ["selectable": false, "reasons": []],
            ]
        }
        let document: [String: Any] = [
            "schema_version": 3, "generated_from_catalog_revision": "fixture", "entries": entries,
            "default_selection": [
                "version": 2, "provider": "piper", "runtime": "piper",
                "model_id": "pt_BR-faber-medium", "model_revision": "fixture", "options": [String: String](),
            ],
        ]
        return try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
    }
}
