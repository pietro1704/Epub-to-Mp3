import Foundation
import XCTest
@testable import EpubToMp3

private final class MaintenanceNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func received() { lock.lock(); value += 1; lock.unlock() }
}

private actor MaintenanceCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        if released { entered = true; return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class AudioStorageMaintenanceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let artifacts: URL
        let downloads: URL
        let tts: URL
        let store: LocalAudioArtifactStore
        let center: NotificationCenter
        let notifications: MaintenanceNotifications
        func service(cancel: @escaping @Sendable () async -> Void = {}) -> AudioStorageMaintenance {
            .init(artifactStore: store, legacyAudiobooksRoot: downloads, legacyTTSRoot: tts,
                  downloadManager: DownloadManager(), cancelDownloads: cancel, notificationCenter: center)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageMaintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let downloads = root.appendingPathComponent("legacy-downloads", isDirectory: true)
        let tts = root.appendingPathComponent("legacy-tts", isDirectory: true)
        let center = NotificationCenter()
        let notifications = MaintenanceNotifications()
        let observer = center.addObserver(forName: ChapterCacheManager.clearAllNotification,
            object: nil, queue: nil) { _ in notifications.received() }
        addTeardownBlock { center.removeObserver(observer) }
        return .init(root: root, artifacts: artifacts, downloads: downloads, tts: tts,
                     store: LocalAudioArtifactStore(root: artifacts), center: center, notifications: notifications)
    }

    private func legacyFile(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("audio.bin")
        try Data([1, 2, 3]).write(to: file)
        return file
    }

    private func prepareAudio(_ store: LocalAudioArtifactStore) async throws -> [URL] {
        try await store.prepare(bookID: "fixture-book", bookTitle: "Fixture", author: nil,
                                chapters: [.init(index: 0, title: "Temporary"), .init(index: 1, title: "Protected")])
        var urls: [URL] = []
        for index in 0...1 {
            let url = try await store.canonicalURL(bookID: "fixture-book", chapterIndex: index)
            try Data([UInt8(index), 1, 2, 3]).write(to: url)
            try await store.markAvailable(bookID: "fixture-book", chapterIndex: index)
            urls.append(url)
        }
        try await store.promote(bookID: "fixture-book", chapterIndex: 1)
        return urls
    }

    func testClearAllWaitsForCancellationAndRemovesOnlyOwnedRoots() async throws {
        let fixture = try fixture()
        let audio = try await prepareAudio(fixture.store)
        let legacy = try legacyFile(in: fixture.downloads)
        let tts = try legacyFile(in: fixture.tts)
        let source = fixture.root.appendingPathComponent("source.epub")
        try Data([7, 8, 9]).write(to: source)
        let gate = MaintenanceCancellationGate()
        let service = fixture.service { await gate.wait() }
        let operation = Task { try await service.clearAllDownloads() }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        for url in audio + [legacy, tts] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(fixture.notifications.count, 0)
        await gate.release()
        try await operation.value
        for url in [fixture.artifacts, fixture.downloads, fixture.tts] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: source), Data([7, 8, 9]))
        XCTAssertEqual(fixture.notifications.count, 1)
    }

    func testMissingRootsAreSuccessfulAndTemporaryCleanupPreservesProtectedAudio() async throws {
        let fixture = try fixture()
        try await fixture.service().clearAllDownloads()
        XCTAssertEqual(fixture.notifications.count, 1)
        let audio = try await prepareAudio(fixture.store)
        let protectedBytes = try Data(contentsOf: audio[1])
        let legacy = try legacyFile(in: fixture.downloads)
        _ = try legacyFile(in: fixture.tts)
        try await fixture.service().clearTemporaryAudio()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio[0].path))
        XCTAssertEqual(try Data(contentsOf: audio[1]), protectedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tts.path))
        let downloaded = try await fixture.store.downloadedIndices(bookID: "fixture-book")
        XCTAssertEqual(downloaded, Set([1]))
        XCTAssertEqual(fixture.notifications.count, 2)
        try await fixture.service().clearTemporaryAudio()
        XCTAssertEqual(fixture.notifications.count, 3)
    }

    #if os(macOS)
    func testLegacyDeletionFailureThrowsWithoutSuccessNotification() async throws {
        let fixture = try fixture()
        let legacy = try legacyFile(in: fixture.downloads)
        let untouchedTTS = try legacyFile(in: fixture.tts)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.downloads.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.downloads.path) }
        do {
            try await fixture.service().clearAllDownloads()
            XCTFail("Denied legacy deletion must propagate")
        } catch {
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedTTS.path))
        XCTAssertEqual(fixture.notifications.count, 0)
    }

    func testTemporaryLegacyDeletionFailureDoesNotReportSuccessOrRemoveDownloads() async throws {
        let fixture = try fixture()
        let legacy = try legacyFile(in: fixture.downloads)
        let tts = try legacyFile(in: fixture.tts)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.tts.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.tts.path) }
        do {
            try await fixture.service().clearTemporaryAudio()
            XCTFail("Denied TTS deletion must propagate")
        } catch {
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tts.path))
        XCTAssertEqual(fixture.notifications.count, 0)
    }

    func testEmbeddedTemporaryDeletionFailurePreservesMetadataAndStopsCleanup() async throws {
        let fixture = try fixture()
        let audio = try await prepareAudio(fixture.store)
        let originalBytes = try Data(contentsOf: audio[0])
        let legacyTTS = try legacyFile(in: fixture.tts)
        let parent = audio[0].deletingLastPathComponent()
        let probe = parent.appendingPathComponent("permission-probe")
        try Data([4]).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try FileManager.default.removeItem(at: probe)) { error in
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }
        do {
            try await fixture.service().clearTemporaryAudio()
            XCTFail("Denied embedded deletion must propagate instead of reporting success")
        } catch {
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }
        XCTAssertEqual(try Data(contentsOf: audio[0]), originalBytes)
        let reopened = LocalAudioArtifactStore(root: fixture.artifacts)
        let artifact = try await reopened.artifact(bookID: "fixture-book", chapterIndex: 0)
        XCTAssertEqual(artifact?.state, .available)
        XCTAssertEqual(artifact?.byteCount, Int64(originalBytes.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyTTS.path))
        XCTAssertEqual(fixture.notifications.count, 0)
    }
    #endif
}
