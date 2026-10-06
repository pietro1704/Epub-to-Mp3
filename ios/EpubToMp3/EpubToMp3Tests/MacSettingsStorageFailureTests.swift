#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacSettingsStorageFailureTests: XCTestCase {
    func testConfirmedRemovalUpdatesOfflineStateOnlyAfterFilesAreRemoved() async throws {
        let gate = RemovalGate()
        let fixture = try await makeFixture(beforeRemoval: { await gate.wait() })
        defer { gate.release(); fixture.cleanup() }
        let button = try clearButton(in: fixture.controller.view)
        button.performClick(nil)
        await waitUntil { fixture.window.attachedSheet != nil }
        XCTAssertEqual(fixture.attempts.count, 0)
        XCTAssertEqual(fixture.library.books.first?.cachedOffline, true)
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        XCTAssertTrue(containsText(L10n.string("settings.clearAllDownloadsConfirmTitle"), in: sheet.contentView))
        let confirm = try XCTUnwrap(views(in: sheet.contentView).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("settings.clearAllDownloads") })
        confirm.performClick(nil)
        await waitUntil { gate.isWaiting && fixture.window.attachedSheet == nil }
        XCTAssertTrue(gate.isWaiting)
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertFalse(fixture.attempts.finished)
        XCTAssertEqual(fixture.library.books.first?.cachedOffline, true)
        XCTAssertEqual(LibraryStore(defaults: fixture.defaults).books.first?.cachedOffline, true)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.bytes)

        // A second real click while removal is pending must not enqueue another operation.
        button.performClick(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertNil(fixture.window.attachedSheet)
        gate.release()
        await waitUntil { fixture.attempts.finished && fixture.library.books.first?.cachedOffline == false }
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertTrue(fixture.attempts.finished)
        XCTAssertFalse(fixture.attempts.failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertEqual(fixture.library.books.first?.cachedOffline, false)
        let reopened = LibraryStore(defaults: fixture.defaults)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.books.first?.id, fixture.library.books.first?.id)
        XCTAssertEqual(reopened.books.first?.cachedOffline, false)
        XCTAssertNil(fixture.window.attachedSheet, "Successful removal must not show an error sheet.")
    }

    @MainActor
    private final class RemovalGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isWaiting = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    func testFailedRemovalShowsErrorAndPreservesOfflineLibraryState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let directories = [fixture.audioURL.deletingLastPathComponent(),
                           fixture.audioURL.deletingLastPathComponent().deletingLastPathComponent(),
                           fixture.root]
        let probe = fixture.audioURL.deletingLastPathComponent().appendingPathComponent("unlink-probe")
        try Data([1]).write(to: probe)
        defer {
            for directory in directories {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            }
        }
        for directory in directories {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        }
        do {
            try FileManager.default.removeItem(at: probe)
            XCTFail("The real filesystem must deny deletion before testing the controller.")
            return
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }

        try clearButton(in: fixture.controller.view).performClick(nil)
        await waitUntil { fixture.attempts.count > 0 || fixture.window.attachedSheet != nil }
        if let sheet = fixture.window.attachedSheet,
           containsText(L10n.string("settings.clearAllDownloadsConfirmTitle"), in: sheet.contentView) {
            let confirm = try XCTUnwrap(views(in: sheet.contentView).compactMap { $0 as? NSButton }
                .first { $0.title == L10n.string("settings.clearAllDownloads")
                    || $0.title == L10n.string("settings.clearCacheConfirmButton") })
            confirm.performClick(nil)
        }
        await waitUntil { fixture.attempts.finished }
        XCTAssertEqual(fixture.attempts.count, 1)
        XCTAssertTrue(fixture.attempts.failed, "The actual artifact-store removal must have failed.")
        await waitUntil {
            self.containsText(L10n.string("settings.storageRemovalFailedTitle"),
                              in: fixture.window.attachedSheet?.contentView)
        }
        XCTAssertTrue(containsText(L10n.string("settings.storageRemovalFailedTitle"),
                                  in: fixture.window.attachedSheet?.contentView),
                      "Settings must present a visible error sheet after filesystem deletion fails.")
        XCTAssertEqual(fixture.library.books.first?.cachedOffline, true)
        let reopened = LibraryStore(defaults: fixture.defaults)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.books.first?.id, fixture.library.books.first?.id)
        XCTAssertEqual(reopened.books.first?.cachedOffline, true)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.bytes)
    }

    func testCancellingRemovalConfirmationDoesNotDeleteOrChangeOfflineState() async throws {
        let fixture = try await makeFixture(performRemoval: false)
        defer { fixture.cleanup() }
        try clearButton(in: fixture.controller.view).performClick(nil)
        await waitUntil { fixture.window.attachedSheet != nil || fixture.attempts.finished }
        XCTAssertEqual(fixture.attempts.count, 0, "Deletion must wait for explicit confirmation.")
        let sheet = try XCTUnwrap(fixture.window.attachedSheet,
                                 "The actual Settings button must present a confirmation sheet.")
        XCTAssertTrue(containsText(L10n.string("settings.clearAllDownloadsConfirmTitle"), in: sheet.contentView))
        let cancel = try XCTUnwrap(views(in: sheet.contentView).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("library.cancel") || $0.title == L10n.string("common.cancel") })
        cancel.performClick(nil)
        await waitUntil { fixture.window.attachedSheet == nil }
        XCTAssertEqual(fixture.attempts.count, 0)
        XCTAssertEqual(fixture.library.books.first?.cachedOffline, true)
        let reopened = LibraryStore(defaults: fixture.defaults)
        XCTAssertEqual(reopened.books.count, 1)
        XCTAssertEqual(reopened.books.first?.id, fixture.library.books.first?.id)
        XCTAssertEqual(reopened.books.first?.cachedOffline, true)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.bytes)
    }

    private final class Attempts {
        var count = 0
        var finished = false
        var failed = false
    }

    private struct Fixture {
        let root: URL
        let audioURL: URL
        let bytes: Data
        let defaults: UserDefaults
        let library: LibraryStore
        let controller: MacSettingsViewController
        let window: NSWindow
        let attempts: Attempts
        let cleanup: () -> Void
    }

    private func makeFixture(
        performRemoval: Bool = true,
        beforeRemoval: (() async -> Void)? = nil
    ) async throws -> Fixture {
        let identifier = "SettingsRemoval-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let book = BookEntity(id: identifier, title: "Removal fixture", bookmark: Data([1]),
                              displayFilename: "fixture.epub", addedAt: .now, cachedOffline: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")
        let library = LibraryStore(defaults: defaults)
        // LibraryStore synchronously prunes empty bookmarks while decoding.
        // Require a loaded offline record before exercising any UI action.
        XCTAssertEqual(library.books.count, 1)
        let loadedBook = try XCTUnwrap(library.books.first)
        XCTAssertEqual(loadedBook.id, identifier)
        XCTAssertTrue(loadedBook.cachedOffline)
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(bookID: identifier, bookTitle: book.title, author: nil,
                                chapters: [.init(index: 0, title: "Chapter")])
        let audioURL = try await store.canonicalURL(bookID: identifier, chapterIndex: 0)
        let bytes = Data(repeating: 0xA3, count: 128)
        try bytes.write(to: audioURL)
        try await store.markAvailable(bookID: identifier, chapterIndex: 0)
        try await store.requestPlaybackRetention(bookID: identifier, chapterIndex: 0)
        let attempts = Attempts()
        let controller = MacSettingsViewController(settings: AppSettings(defaults: defaults), library: library,
            diagnosticsSession: StreamingDiagnosticsSession(), clearDownloadsOperation: {
                attempts.count += 1
                defer { attempts.finished = true }
                guard performRemoval else { return }
                await beforeRemoval?()
                do { try await store.clearAllAudio() }
                catch { attempts.failed = true; throw error }
            })
        let previousKeyWindow = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return Fixture(root: root, audioURL: audioURL, bytes: bytes, defaults: defaults,
                       library: library, controller: controller, window: window, attempts: attempts,
                       cleanup: {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.orderOut(nil)
            window.contentViewController = nil
            previousKeyWindow?.makeKey()
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func clearButton(in view: NSView) throws -> NSButton {
        try XCTUnwrap(views(in: view).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("settings.clearAllDownloads") })
    }

    private func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func containsText(_ text: String, in view: NSView?) -> Bool {
        views(in: view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
