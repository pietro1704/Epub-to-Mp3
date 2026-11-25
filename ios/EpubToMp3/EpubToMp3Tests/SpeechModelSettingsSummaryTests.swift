import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelSettingsSummaryTests: XCTestCase {
    func testSummaryKeepsReadinessAndActiveFailureOrCancelledTransferDiscoverable() {
        let entry = entry()
        let state = SpeechModelLibraryViewState(snapshot: .init(schemaVersion: 3,
            generatedFromCatalogRevision: "fixture", defaultSelection: .init(provider: "piper", runtime: "piper",
                modelID: entry.identity.modelID), target: nil, entries: [entry]))
        let selection = TtsSelection(engine: "piper", modelID: entry.identity.modelID)
        let initial = SpeechModelSettingsSummary.text(state: state, primary: selection, events: [:])
        XCTAssertTrue(initial.contains("Faber"))
        XCTAssertTrue(initial.contains(L10n.string("settings.modelState.ready")))
        for stage in [SpeechModelInstallEvent.Stage.downloading, .failed, .cancelled] {
            let event = SpeechModelInstallEvent(sequence: 1, operationID: "fixture", modelID: entry.identity.modelID,
                stage: stage, artifactIndex: nil, bytesCompleted: 50, bytesTotal: 100, failure: nil)
            let summary = SpeechModelSettingsSummary.text(state: state, primary: selection,
                events: [entry.identity.modelID: event])
            XCTAssertTrue(summary.contains(state.installStatus(for: event)))
        }
        let foreign = SpeechModelInstallEvent(sequence: 1, operationID: "foreign", modelID: "another-book-model",
            stage: .failed, artifactIndex: nil, bytesCompleted: 0, bytesTotal: 0, failure: nil)
        XCTAssertEqual(SpeechModelSettingsSummary.text(state: state, primary: selection,
            events: [entry.identity.modelID: foreign]), initial)
    }

    private func entry() -> SpeechModelSnapshot.Entry {
        .init(identity: .init(provider: "piper", runtime: "piper", modelID: "pt_BR-faber-medium", modelRevision: "fixture"),
            presentation: .init(modelName: "Faber", familyName: "Piper", quality: .medium, voiceChoices: []),
            languageEvidence: .init(routingTags: ["pt"], exactTags: []),
            distribution: .init(installable: true, downloadBytes: nil, installedBytes: nil),
            licence: .init(id: nil, category: "unknown", evidenceURL: nil, termsFingerprint: nil, requiresAcceptance: false, validation: "unknown"),
            compatibility: .init(compatible: true, reasons: []),
            installation: .init(state: .installed, verifiedRevision: "fixture", installedBytes: nil),
            readiness: .init(state: .ready, activeRuntimeRevision: "fixture", failure: nil),
            selection: .init(selectable: true, reasons: []))
    }
}
