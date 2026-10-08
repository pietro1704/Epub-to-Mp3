#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderDiskCacheTests: XCTestCase {
    func testPreparedDiskReaderDoesNotRewriteValidatedPayload() async throws {
        let id = UUID().uuidString
        let suite = "MacReaderDiskCacheTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys = ["readerWarmBookIDs.v1", ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let payload = EbookFulltext(jobId: id, bookTitle: "Disk fixture", bookAuthor: nil,
            chapters: [.init(index: 0, name: "Prepared chapter",
                text: "Prepared text remains readable without rewriting its durable cache.",
                html: "<p>Prepared <strong>text</strong> remains readable without rewriting its durable cache.</p>",
                css: nil, charCount: 70, segments: nil)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(payload)
        let cache = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try bytes.write(to: cache, options: .atomic)
        let modified = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: cache.path)
        // A nonempty unresolved bookmark keeps the row valid; the disk fast path
        // must never resolve it or need a source file.
        let book = BookEntity(id: id, title: "Disk fixture", bookmark: Data([1]),
                              displayFilename: "fixture.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.\(id)")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library.\(id)")
        XCTAssertEqual(library.books.map(\.id), [id])
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        UserDefaults.standard.set(id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let controller = MacReaderViewController(library: library, settings: AppSettings(defaults: defaults),
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "fixture"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close(); player.stop()
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        XCTAssertNil(LocalFulltextCache.inMemoryPayload(bookId: id))
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        var ready = false
        for _ in 0..<500 {
            ready = LatencyObservationStore.shared.snapshot().contains {
                !known.contains($0.id) && $0.context.cacheClass == .preparedDisk
                    && $0.records.contains { $0.transition == .readableContent }
                    && $0.records.contains { $0.transition == .controlsUsable }
            }
            if ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ready, "The actual reader must present the disk-prepared chapter and usable controls")
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date,
                       modified, "Opening valid prepared content must not rewrite its cache")
    }
}
#endif
