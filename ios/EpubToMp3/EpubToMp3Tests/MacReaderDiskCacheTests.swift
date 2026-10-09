#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderDiskCacheTests: XCTestCase {
    func testActualReaderConsumesPreparedArchiveAndInvalidatesChangedSettings() async throws {
        let id = UUID().uuidString
        let suite = "MacReaderDiskCacheTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let keys = ["readerWarmBookIDs.v1", ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let chapter = EbookFulltext.Chapter(index: 8, name: "Source chapter eight",
            text: "HTML fallback content", html: "<p>HTML fallback content</p>",
            css: nil, charCount: 21, segments: nil)
        let settings = AppSettings(defaults: defaults)
        let store = PreparedChapterArchiveStore(directory: root)
        let producer = PreparedChapterRenderer(store: store)
        XCTAssertNotNil(producer.render(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
        await producer.flush()
        let archives = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertEqual(archives.count, 1)
        let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: archive), format: nil) as? [String: Any])
        let markerKey = NSAttributedString.Key("test.preparedArchive")
        let prepared = try XCTUnwrap(producer.cached(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
        let marked = NSMutableAttributedString(attributedString: prepared)
        marked.addAttribute(markerKey, value: id, range: NSRange(location: 0, length: marked.length))
        let markerData = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(attributedString: marked),
                                                      requiringSecureCoding: true)
        try await store.write(markerData, bookID: id, chapterIndex: 0,
                              signature: try XCTUnwrap(envelope["signature"] as? String))
        let renderer = PreparedChapterRenderer(store: store)
        XCTAssertNil(renderer.cached(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
        let payload = EbookFulltext(jobId: id, bookTitle: "Archive fixture", bookAuthor: nil, chapters: [chapter])
        let cache = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try JSONEncoder().encode(payload).write(to: cache, options: .atomic)
        let book = BookEntity(id: id, title: "Archive fixture", bookmark: Data([1]),
                              displayFilename: "fixture.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.\(id)")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library.\(id)")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        UserDefaults.standard.set(id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        ReaderProgressStore.save(bookId: id, chapterIndex: 0, offsetFraction: 0)
        let controller = MacReaderViewController(library: library, settings: settings,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "fixture"),
            onClose: {}, preparedRenderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil; window.close(); player.stop() }
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        for _ in 0..<500 {
            if LatencyObservationStore.shared.snapshot().contains(where: {
                !known.contains($0.id) && $0.context.cacheClass == .preparedDisk
                    && $0.records.contains { $0.transition == .readableContent }
                    && $0.records.contains { $0.transition == .controlsUsable }
            }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        XCTAssertEqual(textView.string, prepared.string)
        XCTAssertEqual(textView.textStorage?.attribute(markerKey, at: 0, effectiveRange: nil) as? String, id)
        XCTAssertTrue(LatencyObservationStore.shared.snapshot().contains {
            !known.contains($0.id) && $0.context.cacheClass == .preparedDisk
                && $0.records.contains { $0.transition == .readableContent }
                && $0.records.contains { $0.transition == .controlsUsable }
        })
        settings.readerFontSize = settings.readerFontSize == 4 ? 0 : 4
        XCTAssertNil(renderer.cached(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
        controller.setBook(id)
        for _ in 0..<500 {
            if textView.textStorage?.attribute(markerKey, at: 0, effectiveRange: nil) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await renderer.flush()
        XCTAssertEqual(textView.string.trimmingCharacters(in: .whitespacesAndNewlines), chapter.text)
        XCTAssertNil(textView.textStorage?.attribute(markerKey, at: 0, effectiveRange: nil))
        XCTAssertNotNil(renderer.cached(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    func testPreparedDiskReaderDoesNotRewriteValidatedPayload() async throws {
        let id = UUID().uuidString
        let suite = "MacReaderDiskCacheTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: archiveRoot))
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
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "fixture"),
            onClose: {}, preparedRenderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close(); player.stop()
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
            defaults.removePersistentDomain(forName: suite)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: archiveRoot)
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
        await renderer.flush()
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date,
                       modified, "Opening valid prepared content must not rewrite its cache")
    }
}
#endif
