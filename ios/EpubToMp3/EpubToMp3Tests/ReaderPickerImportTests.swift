#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import EpubToMp3

private final class ReaderPickerCopyProbe: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@MainActor @Sendable () -> Void)?
    private var didTimeout = false
    func arm(_ action: @escaping @MainActor @Sendable () -> Void) { lock.lock(); callback = action; lock.unlock() }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeout }
    override func copyItem(at source: URL, to destination: URL) throws {
        lock.lock(); let action = callback; callback = nil; lock.unlock()
        if let action {
            XCTAssertFalse(Thread.isMainThread)
            let release = DispatchSemaphore(value: 0)
            Task { @MainActor in action(); release.signal() }
            if release.wait(timeout: .now() + 2) != .success {
                lock.lock(); didTimeout = true; lock.unlock()
            }
        }
        try super.copyItem(at: source, to: destination)
    }
}

@MainActor
final class ReaderPickerImportTests: XCTestCase {
    func testPickerKeepsMainActorAvailableAndPublishesDurableImport() async throws {
        try await verifyImport(changeSelection: false)
    }

    func testBookChangeDuringImportCannotBeOverwrittenByItsCompletion() async throws {
        try await verifyImport(changeSelection: true)
    }

    private func verifyImport(changeSelection: Bool) async throws {
        let id = "reader-picker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let source = try EpubFixture.createWithChapter(body: "An imported replacement chapter.")
        let original = try Data(contentsOf: source)
        let probe = ReaderPickerCopyProbe()
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", fileManager: probe,
                                   importDirectory: root)
        let initial = BookEntity(id: "\(id)-initial", title: "Initial", bookmark: Data([1]),
                                 displayFilename: "initial.epub", addedAt: Date())
        let newer = BookEntity(id: "\(id)-newer", title: "Newer", bookmark: Data([1]),
                               displayFilename: "newer.epub", addedAt: Date())
        defaults.set(initial.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let reader = BookOpenScreenController(book: initial, library: library,
            settings: AppSettings(defaults: defaults), bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            player: player, sessionDefaults: defaults)
        let heartbeat = expectation(description: "Main actor runs during picker copy")
        defer {
            player.stop(); defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source)
        }
        probe.arm {
            if changeSelection {
                reader.update(book: newer)
                defaults.set(newer.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            }
            heartbeat.fulfill()
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.epub], asCopy: false)
        reader.documentPicker(picker, didPickDocumentsAt: [source])
        await fulfillment(of: [heartbeat], timeout: 3)
        for _ in 0..<200 {
            if !library.books.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(probe.timedOut, "The picker caller must not synchronously block MainActor on the IO queue")
        let imported = try XCTUnwrap(library.books.first)
        try await library.flushPersistence()
        let reloaded = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        XCTAssertEqual(reloaded.books.first?.id, imported.id)
        for _ in 0..<200 {
            let selected = defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
            if selected == (changeSelection ? newer.id : imported.id) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
                       changeSelection ? newer.id : imported.id)
        XCTAssertEqual(try Data(contentsOf: source), original)
        withExtendedLifetime(reader) { }
    }
}
#endif
