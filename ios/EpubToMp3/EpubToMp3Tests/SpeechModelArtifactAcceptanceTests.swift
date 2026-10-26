import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Explicit network acceptance only; normal suites never download public models.
final class SpeechModelArtifactAcceptanceTests: XCTestCase {
    func testOptInAuditedVoicesInstallThroughAppleTransportAndRustVerification() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUB2MP3_MODEL_INSTALL_ACCEPTANCE"] == "1",
              let rootPath = environment["TTS_TEST_INSTALLED_MODELS_ROOT"], rootPath.hasPrefix("/"),
              let idsJSON = environment["TTS_TEST_CATALOG_MODEL_IDS"] else {
            throw XCTSkip("Requires explicit download authorization, isolated models root and JSON model IDs.")
        }
        let ids = try JSONDecoder().decode([String].self, from: Data(idsJSON.utf8))
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(ids.count, Set(ids).count)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let current = SpeechModelLibraryTarget.current()
        XCTAssertNotEqual(root.standardizedFileURL, current.modelsRoot.standardizedFileURL,
                          "Acceptance must not install into the user's application model directory")
        #if APP_FOUNDATION_HOST_TESTS
        let ffi = try XCTUnwrap(environment["APP_FOUNDATION_FFI_LIBRARY"])
        let adapter = ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: ffi))
        #else
        let adapter = ConverterFFIAdapter()
        #endif
        let base = SpeechModelLibraryTarget(
            language: "pt-BR", platform: current.platform, androidAPI: current.androidAPI,
            architecture: current.architecture, osVersion: current.osVersion, modelsRoot: root
        )
        let catalogue = try adapter.speechModelSnapshot(target: base)
        for id in ids {
            let descriptor = try XCTUnwrap(catalogue.entries.first { $0.identity.modelID == id })
            let language = try XCTUnwrap(descriptor.languageEvidence.exactTags.first?.tag)
            XCTAssertTrue(descriptor.distribution.installable)
            XCTAssertFalse(descriptor.licence.requiresAcceptance,
                           "This acceptance cannot accept third-party terms automatically")
            let client = SpeechModelLibraryClient(
                target: base.selectingLanguage(language), adapter: adapter,
                transfer: SpeechModelBackgroundTransfer(configuration: .ephemeral)
            )
            let before = try await client.snapshot(probeRuntime: false)
            let entry = try XCTUnwrap(before.entries.first { $0.identity.modelID == id })
            XCTAssertTrue(entry.compatibility.compatible)
            if entry.installation.state != .installed {
                let stream = await client.watchInstall(modelID: id)
                let observed = Task { () -> [SpeechModelInstallEvent] in
                    var events: [SpeechModelInstallEvent] = []
                    for await event in stream {
                        events.append(event)
                        if !event.isActive { break }
                    }
                    return events
                }
                defer { observed.cancel() }
                let installed = try await installWithDeadline(client, modelID: id)
                XCTAssertEqual(installed.standardizedFileURL, root.appendingPathComponent(id).standardizedFileURL)
                let events = await observed.value
                XCTAssertEqual(events.last?.stage, .completed)
                XCTAssertTrue(events.allSatisfy { $0.modelID == id && $0.failure == nil })
                let operations = Set(events.map(\.operationID))
                XCTAssertEqual(operations.count, 1)
                let counts = events.map(\.bytesCompleted)
                XCTAssertEqual(counts, counts.sorted(), "Real range/fallback progress must stay monotonic")
                XCTAssertEqual(events.last?.bytesCompleted, descriptor.distribution.downloadBytes)
            }
            let after = try await client.snapshot(probeRuntime: false)
            let installed = try XCTUnwrap(after.entries.first { $0.identity.modelID == id })
            XCTAssertEqual(installed.installation.state, .installed)
            XCTAssertEqual(installed.installation.verifiedRevision, descriptor.identity.modelRevision)
            XCTAssertEqual(after.defaultSelection, before.defaultSelection, "Installing never selects a voice")
            print("MODEL_INSTALL_ACCEPTANCE id=\(id) revision=\(installed.installation.verifiedRevision ?? "") bytes=\(installed.installation.installedBytes ?? 0)")
        }
    }

    private func installWithDeadline(_ client: SpeechModelLibraryClient, modelID: String) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await client.install(modelID: modelID) }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            let result = try await group.next()
            return try XCTUnwrap(result)
        }
    }
}
