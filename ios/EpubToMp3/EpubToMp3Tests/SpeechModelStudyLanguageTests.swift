import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelStudyLanguageTests: XCTestCase {
    func testChoosingStudyLanguagePersistsOnlyAfterMatchingSnapshotReturns() async throws {
        let suite = "model-language-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = try snapshot(language: "pt-BR")
        let english = try snapshot(language: "en-US")
        let client = SpeechModelLibraryClient(
            initialSnapshot: initial, loadSnapshot: { english }, languageDefaults: defaults
        )

        let updated = try await client.setStudyLanguage("en-US")

        XCTAssertEqual(updated.target?.language, "en-US")
        XCTAssertEqual(defaults.string(forKey: SpeechModelLibraryTarget.studyLanguageDefaultsKey), "en-US")
        XCTAssertEqual(updated.defaultSelection, initial.defaultSelection)
        XCTAssertTrue(updated.entries.allSatisfy { $0.installation.state == .missing })
        XCTAssertTrue(updated.entries.allSatisfy { !$0.selection.selectable })
        XCTAssertEqual(SpeechModelLibraryViewState(snapshot: updated).studyLanguages, ["en-US", "pt-BR"])
    }

    func testUnknownLanguageAndMismatchedSnapshotNeverOverwritePreference() async throws {
        let suite = "model-language-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pt-BR", forKey: SpeechModelLibraryTarget.studyLanguageDefaultsKey)
        let initial = try snapshot(language: "pt-BR")
        let client = SpeechModelLibraryClient(initialSnapshot: initial, languageDefaults: defaults)
        for language in ["unknown-language", "en-US"] {
            do {
                _ = try await client.setStudyLanguage(language)
                XCTFail("Expected rejection of \(language)")
            } catch {
                XCTAssertEqual(defaults.string(forKey: SpeechModelLibraryTarget.studyLanguageDefaultsKey), "pt-BR")
            }
        }
        let retained = try await client.snapshot()
        XCTAssertEqual(retained.target?.language, "pt-BR")
        XCTAssertEqual(retained.defaultSelection, initial.defaultSelection)
    }

    private func snapshot(language: String) throws -> SpeechModelSnapshot {
        let entries: [[String: Any]] = [
            ("pt_BR-cadu-medium", "Cadu", "pt-BR", "pt"),
            ("en_US-ljspeech-medium", "LJ Speech", "en-US", "en"),
        ].map { id, name, tag, routing in
            [
                "identity": ["provider": "piper", "runtime": "piper", "model_id": id, "model_revision": "fixture"],
                "presentation": ["model_name": name, "family_name": "Piper", "quality": "medium", "voice_choices": []],
                "language_evidence": ["routing_tags": [routing], "exact_tags": [["tag": tag, "validation": "artifact_declared"]]],
                "distribution": ["installable": true, "download_bytes": 10],
                "licence": ["category": "unknown", "requires_acceptance": false, "validation": "unknown"],
                "compatibility": ["compatible": tag == language, "reasons": tag == language ? [] : ["unsupported_language"]],
                "installation": ["state": "missing"],
                "readiness": ["state": "not_inspected"],
                "selection": ["selectable": false, "reasons": ["installation_missing"]],
            ]
        }
        let document: [String: Any] = [
            "schema_version": 3, "generated_from_catalog_revision": "fixture",
            "target": ["language": language], "entries": entries,
            "default_selection": [
                "version": 2, "provider": "piper", "runtime": "piper",
                "model_id": "pt_BR-faber-medium", "model_revision": "fixture", "options": [String: String](),
            ],
        ]
        return try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
    }
}
