#if os(iOS) || os(macOS)
import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
private typealias ModelObservationOwner = SettingsScreenController
#else
import AppKit
private typealias ModelObservationOwner = MacSpeechModelLibraryPanel
#endif

private actor HeldModelInstallation {
    private var completion: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private(set) var requests: [String] = []
    private(set) var wasCancelled = false
    private(set) var completed = false
    var isPending: Bool { completion != nil }

    func install(modelID: String, root: String) async throws -> URL {
        requests.append(modelID)
        destination = URL(fileURLWithPath: root).appendingPathComponent(modelID)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func finish(error: Error? = nil) {
        guard let continuation = completion, let destination else { return }
        completion = nil
        completed = true
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: destination) }
    }

    private func cancel() {
        wasCancelled = true
        finish(error: CancellationError())
    }
}

private final class ModelSnapshotReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class SpeechModelObserverLifetimeTests: XCTestCase {
    func testClosingIdleOwnerDeallocatesItAndTerminatesEveryModelObserver() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var owner: ModelObservationOwner? = fixture.makeOwner()
        weak var releasedOwner = owner
        await waitForObservers(1, fixture: fixture)

        owner = nil

        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedOwner, "An idle never-ending stream must not keep its native screen alive")
        let installs = await fixture.installation.requests
        XCTAssertTrue(installs.isEmpty)
    }

    func testClosingOneOwnerPreservesAnotherOwnersSubscriptions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var first: ModelObservationOwner? = fixture.makeOwner()
        var second: ModelObservationOwner? = fixture.makeOwner()
        weak var releasedFirst = first
        weak var releasedSecond = second
        await waitForObservers(2, fixture: fixture)

        first = nil

        await waitForObservers(1, fixture: fixture)
        XCTAssertNil(releasedFirst)
        XCTAssertNotNil(releasedSecond)
        second = nil
        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedSecond)
    }

    func testRepeatedOpenAndCloseDoesNotAccumulateSubscriptionsOrInstallModels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for _ in 0..<3 {
            var owner: ModelObservationOwner? = fixture.makeOwner()
            weak var releasedOwner = owner
            await waitForObservers(1, fixture: fixture)
            owner = nil
            await waitForObservers(0, fixture: fixture)
            XCTAssertNil(releasedOwner)
        }
        let installs = await fixture.installation.requests
        XCTAssertTrue(installs.isEmpty, "Observing or reopening settings is never installation consent")
    }

    func testClosingOwnerDoesNotCancelItsConfirmedClientInstallation() async throws {
        try await verifyInstallOutlivesOwner(error: nil)
    }

    func testLateInstallationFailureDoesNotKeepOrRecreateClosedOwner() async throws {
        try await verifyInstallOutlivesOwner(error: CocoaError(.fileWriteOutOfSpace))
    }

    func testSuccessfulInstallKeepsLiveOwnerSubscribedUntilItCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var owner: ModelObservationOwner? = fixture.makeOwner()
        weak var releasedOwner = owner
        await waitForObservers(1, fixture: fixture)
        let baselineReads = fixture.reads.value
        let installing = fixture.startConfirmedInstall(on: try XCTUnwrap(owner))
        await waitForPendingInstall(fixture)

        await fixture.installation.finish()
        await installing.value
        await waitForSnapshotReads(baselineReads + 2, fixture: fixture)

        XCTAssertNotNil(releasedOwner)
        await waitForObservers(1, fixture: fixture)
        let cancelled = await fixture.installation.wasCancelled
        XCTAssertFalse(cancelled)
        owner = nil
        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedOwner)
    }

    func testExplicitInstallationCancellationDoesNotEndLiveViewSubscriptions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var owner: ModelObservationOwner? = fixture.makeOwner()
        weak var releasedOwner = owner
        await waitForObservers(1, fixture: fixture)
        let installing = fixture.startConfirmedInstall(on: try XCTUnwrap(owner))
        await waitForPendingInstall(fixture)

        installing.cancel()
        await installing.value

        let cancelled = await fixture.installation.wasCancelled
        XCTAssertTrue(cancelled)
        XCTAssertNotNil(releasedOwner)
        await waitForObservers(1, fixture: fixture)
        owner = nil
        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedOwner)
    }

    private func verifyInstallOutlivesOwner(error: Error?) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var owner: ModelObservationOwner? = fixture.makeOwner()
        weak var releasedOwner = owner
        await waitForObservers(1, fixture: fixture)
        let installing = fixture.startConfirmedInstall(on: try XCTUnwrap(owner))
        await waitForPendingInstall(fixture)

        owner = nil

        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedOwner, "Awaiting an installation must not retain the presenting screen")
        // A RED run must not present a modal error on a leaked owner.
        guard releasedOwner == nil else {
            await fixture.installation.finish()
            await installing.value
            return
        }
        let pending = await fixture.installation.isPending
        let cancelled = await fixture.installation.wasCancelled
        let requests = await fixture.installation.requests
        XCTAssertTrue(pending)
        XCTAssertFalse(cancelled, "Screen teardown cancels its subscription, not the client-owned installation")
        XCTAssertEqual(requests, [Fixture.modelIDs[0]])
        await fixture.installation.finish(error: error)
        await installing.value
        let completed = await fixture.installation.completed
        XCTAssertTrue(completed)
        await waitForObservers(0, fixture: fixture)
        XCTAssertNil(releasedOwner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.modelsRoot.path),
                       "The held installer is a native boundary fixture, never a model download")
    }

    private func waitForObservers(_ expected: Int, fixture: Fixture) async {
        for _ in 0..<200 {
            var counts: [Int] = []
            for modelID in Fixture.modelIDs { counts.append(await fixture.client.installObserverCount(modelID: modelID)) }
            if counts == [expected, expected, 0] { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for (index, modelID) in Fixture.modelIDs.enumerated() {
            let count = await fixture.client.installObserverCount(modelID: modelID)
            XCTAssertEqual(count, index < 2 ? expected : 0, "Subscription ownership must match the exact model")
        }
    }

    private func waitForPendingInstall(_ fixture: Fixture) async {
        for _ in 0..<200 {
            if await fixture.installation.isPending { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The native confirmed-install entry point must reach the held client operation")
    }

    private func waitForSnapshotReads(_ expected: Int, fixture: Fixture) async {
        for _ in 0..<200 {
            if fixture.reads.value >= expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(fixture.reads.value, expected)
    }

    @MainActor
    private final class Fixture {
        static let modelIDs = ["pt_BR-faber-medium", "fixture-other-model", "fixture-not-installable"]
        let suite = "speech-model-lifetime-\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let modelsRoot: URL
        let settings: AppSettings
        let snapshot: SpeechModelSnapshot
        let reads = ModelSnapshotReadCount()
        let installation = HeldModelInstallation()
        let client: SpeechModelLibraryClient

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
            modelsRoot = root.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            settings = AppSettings(defaults: defaults)
            snapshot = try Self.makeSnapshot()
            let initial = snapshot
            let counter = reads
            let gate = installation
            let target = SpeechModelLibraryTarget(language: "pt-BR", platform: "fixture", androidAPI: 0,
                architecture: "fixture", osVersion: "fixture", modelsRoot: modelsRoot)
            client = SpeechModelLibraryClient(initialSnapshot: initial,
                loadSnapshot: { counter.record(); return initial },
                installAsync: { modelID, root in try await gate.install(modelID: modelID, root: root) }, target: target)
        }

        func makeOwner() -> ModelObservationOwner {
            #if os(iOS)
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            let owner = SettingsScreenController(settings: settings,
                library: LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library")),
                player: player, playbackClock: PlaybackClock(),
                termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults), speechModels: client)
            owner.loadViewIfNeeded()
            #else
            let owner = MacSpeechModelLibraryPanel(settings: settings, speechModels: client,
                                                  termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults))
            owner.reload()
            #endif
            return owner
        }

        func startConfirmedInstall(on owner: ModelObservationOwner) -> Task<Void, Never> {
            let entry = snapshot.entries[0]
            #if os(iOS)
            return owner.install(entry, title: "Native installation fixture", acceptedTermsFingerprint: nil)
            #else
            return owner.install(entry, acceptedTermsFingerprint: nil)
            #endif
        }

        private static func makeSnapshot() throws -> SpeechModelSnapshot {
            let entries: [[String: Any]] = modelIDs.enumerated().map { index, modelID in
                ["identity": ["provider": "piper", "runtime": "piper", "model_id": modelID, "model_revision": "fixture-revision"],
                 "presentation": ["model_name": "Fixture voice \(index)", "family_name": "Piper", "quality": "medium",
                                  "voice_choices": [["voice_id": NSNull(), "name": "Fixture voice"]]],
                 "language_evidence": ["routing_tags": ["pt"],
                                       "exact_tags": [["tag": "pt-BR", "frontend": "fixture", "validation": "runtime_validated"]]],
                 "distribution": ["installable": index < 2, "download_bytes": 1, "installed_bytes": 1],
                 "licence": ["id": "fixture", "category": "dataset", "evidence_url": "https://example.invalid/model",
                             "requires_acceptance": false, "validation": "partial"],
                 "compatibility": ["compatible": true, "reasons": [String]()],
                 "installation": ["state": "missing", "verified_revision": NSNull(), "installed_bytes": 0],
                 "readiness": ["state": "not_inspected", "active_runtime_revision": NSNull(), "failure": NSNull()],
                 "selection": ["selectable": false, "reasons": [String]()]]
            }
            let document: [String: Any] = ["schema_version": 3, "generated_from_catalog_revision": "fixture-catalog",
                "default_selection": ["version": 2, "provider": "piper", "runtime": "piper", "model_id": modelIDs[0],
                                      "model_revision": "fixture-revision", "voice": NSNull(), "options": [String: String]()], "entries": entries]
            return try SpeechModelSnapshot.decode(JSONSerialization.data(withJSONObject: document))
        }

        func cleanUp() {
            let gate = installation
            Task { await gate.finish() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
