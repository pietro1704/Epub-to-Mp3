import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class AuditVoiceUsabilityTests: XCTestCase {
    func testInstalledForeignLanguageVoiceOffersPreviewWithoutSelection() throws {
        let entry = entry(compatible: false)
        let state = state(entry)
        let actions = state.actions(for: entry, configuredSelections: [], installEvent: nil, termsAccepted: false)
        XCTAssertTrue(actions.available.contains(.preview))
        XCTAssertFalse(actions.available.contains(.select))
        XCTAssertNil(state.selection(for: entry))
        let summary = state.rowSummary(for: entry, configuredSelections: [])
        XCTAssertTrue(summary.contains(L10n.string("settings.modelCompatibility.otherLanguage")))
        XCTAssertFalse(summary.contains(L10n.string("settings.modelPerformance.unmeasured")))
        XCTAssertFalse(summary.contains(L10n.string("settings.modelState.readinessNotInspected")))
    }

    func testMissingForeignLanguageVoiceDoesNotPromiseAnInstalledPreview() {
        let entry = entry(compatible: false, installation: .missing)
        let state = state(entry)
        XCTAssertFalse(state.actions(for: entry, configuredSelections: [], installEvent: nil, termsAccepted: false)
            .available.contains(.preview))
        XCTAssertFalse(state.rowSummary(for: entry, configuredSelections: [])
            .contains(L10n.string("settings.modelCompatibility.otherLanguage")))
    }

    func testPreviewCapturesVoiceInItsOwnLanguageWithoutChangingStudyLanguage() async throws {
        let foreign = entry(compatible: false)
        let snapshot = state(entry(compatible: true)).snapshot!
        let client = SpeechModelLibraryClient(initialSnapshot: snapshot)
        let choice = try await client.auditionChoice(for: foreign)
        XCTAssertEqual(choice.language, "pt-BR")
        XCTAssertEqual(choice.selection.modelID, foreign.identity.modelID)
        XCTAssertEqual(choice.selection.session?.modelRevision, "fixture")
        let after = try await client.snapshot()
        XCTAssertEqual(after.target?.language, snapshot.target?.language)
        do {
            _ = try await client.auditionChoice(for: entry(compatible: false, revision: "replaced"))
            XCTFail("A replaced model must not change the captured audition identity")
        } catch { }
        let wrongLanguage = SpeechModelLibraryClient(initialSnapshot: .init(schemaVersion: 3,
            generatedFromCatalogRevision: "fixture", defaultSelection: snapshot.defaultSelection,
            target: .init(language: "en-US"), entries: snapshot.entries))
        do {
            _ = try await wrongLanguage.auditionChoice(for: foreign)
            XCTFail("Audition must not silently use a different language")
        } catch { }
    }

    private func state(_ entry: SpeechModelSnapshot.Entry) -> SpeechModelLibraryViewState {
        .init(snapshot: .init(schemaVersion: 3, generatedFromCatalogRevision: "fixture",
            defaultSelection: .init(provider: "piper", runtime: "piper", modelID: entry.identity.modelID),
            target: .init(language: "pt-BR"), entries: [entry]))
    }

    private func entry(compatible: Bool, revision: String = "fixture",
                       installation: SpeechModelSnapshot.InstallationState = .installed) -> SpeechModelSnapshot.Entry {
        .init(identity: .init(provider: "piper", runtime: "piper", modelID: "pt_BR-faber-medium", modelRevision: revision),
            presentation: .init(modelName: "Faber", familyName: "Piper", quality: .medium, voiceChoices: []),
            languageEvidence: .init(routingTags: ["pt"], exactTags: [.init(tag: "pt-BR", frontend: nil, validation: "artifact_declared")]),
            distribution: .init(installable: true, downloadBytes: nil, installedBytes: nil),
            licence: .init(id: nil, category: "unknown", evidenceURL: nil, termsFingerprint: nil, requiresAcceptance: false, validation: "unknown"),
            compatibility: .init(compatible: compatible, reasons: compatible ? [] : ["unsupported_language"]),
            installation: .init(state: installation, verifiedRevision: "fixture", installedBytes: nil),
            readiness: .init(state: compatible ? .ready : .notInspected, activeRuntimeRevision: nil, failure: nil),
            selection: .init(selectable: compatible && installation == .installed, reasons: []))
    }
}
