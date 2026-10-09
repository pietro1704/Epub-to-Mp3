#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class PreparedChapterReaderIntegrationTests: XCTestCase {
    func testActualUIKitReaderConsumesPreparedArchive() async throws {
        let id = "PreparedUIKit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let keys = ["readerWarmBookIDs.v1", ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            LocalFulltextCache.evict(bookId: id); ReaderProgressStore.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .light
        settings.readerLayout = .paginated
        let chapter = EbookFulltext.Chapter(index: 1, name: "Prepared chapter",
            text: "Prepared text with native styling and an internal link remains readable in the native reader.",
            html: "<p><b>Prepared text</b> with native styling and an <a href='#note'>internal link</a> remains readable in the native reader.</p>",
            css: nil, charCount: 95, segments: nil)
        let directory = root.appendingPathComponent("archives", isDirectory: true)
        let store = PreparedChapterArchiveStore(directory: directory)
        let producer = PreparedChapterRenderer(store: store)
        let rendered = try XCTUnwrap(producer.render(bookID: id, chapterIndex: 0, chapter: chapter, settings: settings))
        await producer.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let marker = NSAttributedString.Key("test.preparedArchive")
        let marked = NSMutableAttributedString(attributedString: rendered)
        marked.addAttribute(marker, value: id, range: NSRange(location: 0, length: marked.length))
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(attributedString: marked), requiringSecureCoding: true)
        try await store.write(data, bookID: id, chapterIndex: 0, signature: try XCTUnwrap(envelope["signature"] as? String))
        let payload = EbookFulltext(jobId: id, bookTitle: "Prepared fixture", bookAuthor: nil, chapters: [chapter])
        try JSONEncoder().encode(payload).write(to: try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id)), options: .atomic)
        let book = BookEntity(id: id, title: "Prepared fixture", bookmark: Data([1]), displayFilename: "fixture.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.\(id)")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library.\(id)")
        ReaderProgressStore.save(bookId: id, chapterIndex: 0, offsetFraction: 0)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let renderer = PreparedChapterRenderer(store: store)
        let controller = BookOpenScreenController(book: book, library: library, settings: settings,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "fixture"), player: player, preparedRenderer: renderer)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true; window.rootViewController = nil; player.stop() }
        XCTAssertNil(LocalFulltextCache.inMemoryPayload(bookId: id))
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        var ready = false
        for _ in 0..<500 {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            ready = LatencyObservationStore.shared.snapshot().contains {
                !known.contains($0.id) && $0.context.cacheClass == .preparedDisk
                    && $0.records.contains { $0.transition == .readableContent }
                    && $0.records.contains { $0.transition == .controlsUsable }
            }
            if ready { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let observed = LatencyObservationStore.shared.snapshot().filter { !known.contains($0.id) }
            .map { "\($0.context.cacheClass.rawValue):\($0.records.map { $0.transition.rawValue })" }
        XCTAssertTrue(ready, "Reader ready journeys: \(observed)")
        let textView = try XCTUnwrap(findTextView(controller.view))
        XCTAssertEqual(textView.attributedText.string, rendered.string)
        XCTAssertEqual(textView.attributedText.attribute(marker, at: 0, effectiveRange: nil) as? String, id)
        XCTAssertFalse(controller.isLoadingBookContent)
        await renderer.flush()
    }

    private func findTextView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView($0) }.first
    }
}
#endif
