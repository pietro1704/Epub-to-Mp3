import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

private final class SnapshotReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failFrom: Int?
    init(failFrom: Int? = nil) { self.failFrom = failFrom }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func shouldFail(_ read: Int) -> Bool { failFrom.map { read >= $0 } ?? false }
}

private final class InstallRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

private enum FixtureFailure: Error { case catalogue, install }

/// The shared voice-model session used by iOS settings and the Mac model panel.
@MainActor
final class SpeechModelLibrarySessionTests: XCTestCase {
    private static let modelID = "pt_BR-faber-medium"

    func testInstallWhoseCatalogueRefreshFailsIsNotReportedAsAFailedInstall() async throws {
        // Read 1 is the client's own pre-install check; read 2 is the session's refresh.
        let reads = SnapshotReads(failFrom: 2)
        let requests = InstallRequests()
        var logged: [Error] = []
        let (session, root) = try makeSession(reads: reads, requests: requests) { logged.append($0) }
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var changes: [SpeechModelLibrarySession.Change] = []
        session.onFailure = { title, _, _ in failures.append(title) }
        session.onChange = { changes.append($0) }
        let before = session.state.entries.map(\.identity.modelID)

        await session.install(try entry(in: session), acceptedTermsFingerprint: nil).value

        XCTAssertEqual(requests.value, [Self.modelID], "The confirmed install reached the client")
        XCTAssertTrue(failures.isEmpty, "A failed refresh after a successful install is not an install failure")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first is FixtureFailure)
        XCTAssertEqual(changes, [.catalog], "The list renders again and refreshes on the next snapshot")
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(session.state.entries.map(\.identity.modelID), before, "The last valid catalogue is kept")
    }

    func testFailedInstallReportsTheInstallTitle() async throws {
        let (session, root) = try makeSession(reads: SnapshotReads(), requests: InstallRequests(), installFails: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        session.onFailure = { title, _, _ in failures.append(title) }
        let target = try entry(in: session)

        await session.install(target, acceptedTermsFingerprint: nil).value

        XCTAssertEqual(failures, [session.state.installTitle(for: target)])
    }

    func testEventsForModelsOutsideTheCatalogueAreIgnored() throws {
        let (session, root) = try makeSession(reads: SnapshotReads(), requests: InstallRequests())
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(session.apply(event(modelID: "missing-model")))
        XCTAssertNil(session.installEvents["missing-model"])
        XCTAssertTrue(session.apply(event(modelID: Self.modelID)))
        XCTAssertEqual(session.installEvents[Self.modelID]?.stage, .downloading)
    }

    func testSuccessfulInstallObservesInstallsAgain() async throws {
        let reads = SnapshotReads()
        let (session, root) = try makeSession(reads: reads, requests: InstallRequests())
        defer { try? FileManager.default.removeItem(at: root) }
        let initialObservers = await session.client.installObserverCount(modelID: Self.modelID)
        XCTAssertEqual(initialObservers, 0, "Nothing observes before the first catalogue")

        await session.install(try entry(in: session), acceptedTermsFingerprint: nil).value

        XCTAssertEqual(reads.value, 2, "The client checks the catalogue, then the session reads it again")
        var observers = 0
        for _ in 0..<200 {
            observers = await session.client.installObserverCount(modelID: Self.modelID)
            if observers == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observers, 1, "The refreshed catalogue is observed again")
    }

    func testRemovalOfAConfiguredModelIsRefusedWithTheRemovalTitle() async throws {
        let (session, root) = try makeSession(reads: SnapshotReads(), requests: InstallRequests())
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        session.onFailure = { title, _, _ in failures.append(title) }
        let target = try entry(in: session)
        await session.remove(target, configuredSelections: [.defaultPiper]).value

        XCTAssertEqual(failures, [L10n.string("settings.modelRemove.failed")])
        XCTAssertEqual(session.state.entries.map(\.identity.modelID), [Self.modelID])
    }

    // MARK: - Fixture

    private func makeSession(reads: SnapshotReads, requests: InstallRequests, installFails: Bool = false,
                             logRefreshFailure: ((Error) -> Void)? = nil) throws -> (SpeechModelLibrarySession, URL) {
        let snapshot = try SpeechModelSnapshot.decode(Self.snapshotJSON)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-session-\(UUID().uuidString)")
        let target = SpeechModelLibraryTarget(language: "pt-BR", platform: "fixture", androidAPI: 0,
            architecture: "fixture", osVersion: "fixture", modelsRoot: root.appendingPathComponent("models"))
        let client = SpeechModelLibraryClient(
            initialSnapshot: snapshot,
            loadSnapshot: {
                let read = reads.next()
                if reads.shouldFail(read) { throw FixtureFailure.catalogue }
                return snapshot
            },
            installAsync: { modelID, root in
                requests.record(modelID)
                if installFails { throw FixtureFailure.install }
                // A native boundary fixture: nothing is downloaded or written.
                return URL(fileURLWithPath: root).appendingPathComponent(modelID)
            },
            remove: { _, _ in },
            target: target)
        let session = logRefreshFailure.map { SpeechModelLibrarySession(client: client, logRefreshFailure: $0) }
            ?? SpeechModelLibrarySession(client: client)
        return (session, root)
    }

    private func entry(in session: SpeechModelLibrarySession) throws -> SpeechModelSnapshot.Entry {
        try XCTUnwrap(session.state.entries.first { $0.identity.modelID == Self.modelID })
    }

    private func event(modelID: String) -> SpeechModelInstallEvent {
        .init(sequence: 1, operationID: "fixture", modelID: modelID, stage: .downloading, artifactIndex: nil,
              bytesCompleted: 1, bytesTotal: 2, failure: nil)
    }

    private static let snapshotJSON = Data("""
    {
      "schema_version": 3,
      "generated_from_catalog_revision": "catalog-revision",
      "default_selection": {"version": 2, "provider": "piper", "runtime": "piper",
        "model_id": "pt_BR-faber-medium", "model_revision": "model-revision", "voice": null, "options": {}},
      "entries": [{
        "identity": {"provider": "piper", "runtime": "piper", "model_id": "pt_BR-faber-medium",
          "model_revision": "model-revision"},
        "presentation": {"model_name": "Faber", "family_name": "Piper", "quality": "medium",
          "voice_choices": [{"voice_id": null, "name": "Faber"}]},
        "language_evidence": {"routing_tags": ["pt"],
          "exact_tags": [{"tag": "pt-BR", "frontend": "espeak-ng:pt-br", "validation": "runtime_validated"}]},
        "distribution": {"installable": true, "download_bytes": 1, "installed_bytes": 1},
        "licence": {"id": "CC0-1.0", "category": "dataset", "evidence_url": "https://example.invalid/model-card",
          "terms_fingerprint": null, "requires_acceptance": false, "validation": "partial"},
        "compatibility": {"compatible": true, "reasons": []},
        "installation": {"state": "missing", "verified_revision": null, "installed_bytes": 0},
        "readiness": {"state": "not_inspected", "active_runtime_revision": null, "failure": null},
        "selection": {"selectable": false, "reasons": []}
      }]
    }
    """.utf8)
}
