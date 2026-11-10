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

    func testConsumedProjectionCannotRemountAfterCatalogHydrationAndTOCNavigation() async throws {
        try await verifyProjectionRestoration(delayedLayout: false)
    }

    func testProjectionRestoresPositionOnlyAfterTextLayoutIsMeasured() async throws {
        try await verifyProjectionRestoration(delayedLayout: true)
    }

    private func verifyProjectionRestoration(delayedLayout: Bool) async throws {
        let id = "ConsumedProjection-\(UUID().uuidString)"
        let savedWarmBooks = UserDefaults.standard.object(forKey: "readerWarmBookIDs.v1")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let store = PreparedReaderChapterStore(directory: root)
        let payload = EbookFulltext(jobId: id, bookTitle: "Projection identity", bookAuthor: nil,
            chapters: (1...2).map { index in
                .init(index: index, name: "Chapter \(index)", text: "Chapter \(index) readable text.",
                      html: nil, css: nil, charCount: 24, segments: nil)
            })
        LocalFulltextCache.save(payload, bookId: id)
        defer {
            LocalFulltextCache.evict(bookId: id)
            UserDefaults.standard.set(savedWarmBooks, forKey: "readerWarmBookIDs.v1")
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let source = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        try await store.write(bookID: id, chapterOrdinal: 0, fulltextURL: source)
        let stored = await store.read(bookID: id, chapterOrdinal: 0, fulltextURL: source)
        let snapshot = try XCTUnwrap(stored)
        let document = ReaderBookDocument(book: BookEntity(id: id, title: "Projection identity",
            bookmark: Data(), displayFilename: "projection.epub", addedAt: Date()))
        let loadingID = UUID()
        document.loadGenerationID = loadingID
        document.activeLoadingID = loadingID
        let settings = AppSettings(defaults: defaults)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: root.appendingPathComponent("renderings")))
        var mountedChapters: [Int] = []
        var textIsLaidOut = !delayedLayout
        var restoredPositions = 0
        let presentation = ReaderPreparedPresentation(document: document, settings: settings,
            renderer: renderer, store: store, stageObserver: nil,
            viewportIsCommitted: { true }, textIsLaidOut: { textIsLaidOut }, send: { event in
                if case let .showChapter(index, _) = event { mountedChapters.append(index) }
                if case .restorePosition = event { restoredPositions += 1 }
            })
        let restoration = PreparedProjectionRestoration(
            projection: PreparedProjectionRead(snapshot: snapshot,
                progress: .init(chapterIndex: 0, offsetFraction: 0.5)),
            style: renderer.styleSnapshot(settings: settings, fontDirectoryURL: nil), renderer: nil)
        // The asynchronous presenter and committed-layout fast path share one
        // result. Hydration releases activePreparedChapter after presentation.
        presentation.restoration.slot.store(restoration)
        presentation.presentPreparedProjection(snapshot, progress: restoration.projection.progress,
            preparedRendering: nil, loadingID: loadingID, bookID: id, fulltextURL: source)
        if delayedLayout {
            XCTAssertEqual(restoredPositions, 0, "Unmeasured text cannot restore a saved position.")
            XCTAssertFalse(document.hasRestoredInitialPosition)
            XCTAssertNotNil(document.pendingProjectionAnchor)
            presentation.finishPreparedProjectionLayoutIfNeeded()
            XCTAssertEqual(restoredPositions, 0)
            textIsLaidOut = true
            presentation.finishPreparedProjectionLayoutIfNeeded()
            XCTAssertEqual(restoredPositions, 1)
            XCTAssertTrue(document.hasRestoredInitialPosition)
        }
        XCTAssertEqual(mountedChapters, [0])
        XCTAssertTrue(presentation.attachHydratedCatalog(payload, loadingID: loadingID))
        document.selectedChapter = 1 // The TOC has selected a different chapter.
        presentation.presentPreparedProjectionDuringCommittedLayoutIfReady()
        XCTAssertEqual(document.selectedChapter, 1, "A later page layout must retain the TOC destination.")
        XCTAssertEqual(mountedChapters, [0], "An already-consumed open snapshot must never mount twice.")
        XCTAssertNil(document.pendingProjectionAnchor)
        // A late delivery to the fast-path slot must obey the same consumed
        // loading identity, even after the async path cleared its first copy.
        presentation.restoration.slot.store(restoration)
        presentation.presentPreparedProjectionDuringCommittedLayoutIfReady()
        XCTAssertEqual(document.selectedChapter, 1)
        XCTAssertEqual(mountedChapters, [0])
        XCTAssertNil(document.pendingProjectionAnchor)
    }

    private func findTextView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView($0) }.first
    }
}
#endif
