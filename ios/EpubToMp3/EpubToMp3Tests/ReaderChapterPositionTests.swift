#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderChapterPositionTests: XCTestCase {
    func testTOCWithoutAudioPreservesDestinationThroughPagesAndReopen() async throws {
        try await verifyTOC(hasAudio: false)
    }

    func testTOCWithAudioPreservesDestinationThroughPagesAndReopen() async throws {
        try await verifyTOC(hasAudio: true)
    }

    private func verifyTOC(hasAudio: Bool) async throws {
        let fixture = try PositionFixture(hasAudio: hasAudio)
        defer { fixture.cleanUp() }
        try await fixture.open()
        try await fixture.turn(forward: true)
        try await fixture.selectChapter(2)
        XCTAssertEqual(ReaderProgressStore.read(bookId: fixture.id)?.chapterIndex, 2,
                       "Selecting a TOC destination must persist it before any page turn or app exit.")
        XCTAssertEqual(ReaderProgressStore.read(bookId: fixture.id)?.offsetFraction, 0)
        try await fixture.turn(forward: true)
        let destinationOffset = try fixture.offset()
        XCTAssertGreaterThan(destinationOffset, 0)
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 2)
        try await fixture.turn(forward: false)
        XCTAssertEqual(try fixture.offset(), 0, accuracy: 0.5)
        try await fixture.turn(forward: true)
        XCTAssertEqual(try fixture.offset(), destinationOffset, accuracy: 0.5)
        let progress = try XCTUnwrap(ReaderProgressStore.read(bookId: fixture.id))
        XCTAssertEqual(progress.chapterIndex, 2)
        fixture.close()
        try await fixture.open()
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 2)
        XCTAssertEqual(try fixture.offset(), destinationOffset, accuracy: 1)
        fixture.close()
        LocalFulltextCache.evictInMemoryPayload(bookId: fixture.id)
        try await fixture.store.write(bookID: fixture.id, chapterOrdinal: 2,
                                     fulltextURL: try XCTUnwrap(LocalFulltextCache.storageURL(bookId: fixture.id)))
        try await fixture.open()
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 2)
        XCTAssertEqual(try fixture.offset(), destinationOffset, accuracy: 1,
                       "A fresh reader using the disk projection must restore the last visible page.")
        try await fixture.turn(forward: true)
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 2)
        XCTAssertGreaterThan(try fixture.offset(), destinationOffset)
        try await fixture.turn(forward: false)
        XCTAssertEqual(try fixture.offset(), destinationOffset, accuracy: 1)
        try await fixture.selectChapter(1)
        try await fixture.selectChapter(0)
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 0)
        XCTAssertEqual(try fixture.offset(), 0, accuracy: 0.5)
        fixture.close()
        try await fixture.open()
        XCTAssertEqual(fixture.controller?.currentReaderChapterIndex, 0)
        XCTAssertEqual(try fixture.offset(), 0, accuracy: 0.5)
    }
}

@MainActor
private final class PositionFixture {
    let id = "ReaderPosition-\(UUID().uuidString)"
    let defaults: UserDefaults
    let player: AudioPlayer
    let settings: AppSettings
    let store: PreparedReaderChapterStore
    let renderer: PreparedChapterRenderer
    let window: UIWindow
    var controller: BookOpenScreenController?
    private let root: URL
    private let saved: [(String, Any?)]
    private let previousWindow: UIWindow?

    init(hasAudio: Bool) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        store = PreparedReaderChapterStore(directory: root.appendingPathComponent("projections"))
        renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: root.appendingPathComponent("renderings")))
        saved = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                 AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey,
                 "readerWarmBookIDs.v1"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let activeWindow = scene?.windows.first(where: \.isKeyWindow)
        previousWindow = activeWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        settings.pageTurnStyle = .none
        player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let chapters: [EbookFulltext.Chapter] = (1...3).map { index in
            let text = "Chapter \(index).\n\n" + String(repeating:
                "Travellers crossed the quiet valley and followed the winding river through the forest.\n\n", count: 90)
            return .init(index: index, name: "Authored chapter \(index)", text: text,
                         html: nil, css: nil, charCount: text.count, segments: nil)
        }
        LocalFulltextCache.save(.init(jobId: id, bookTitle: "Position regression", bookAuthor: nil, chapters: chapters), bookId: id)
        if hasAudio {
            player.setSnapshot(JobSnapshot(jobId: id, state: "finished", bookTitle: "Position regression",
                bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "system", voice: "system",
                language: "en", progressPercent: 100, chaptersTotal: 3, chaptersCompleted: 0,
                chapterProgress: [], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil))
        }
    }

    func open() async throws {
        let diskOpen = LocalFulltextCache.inMemoryPayload(bookId: id) == nil
        let stages = PositionLoadStages()
        let reader = BookOpenScreenController(
            book: BookEntity(id: id, title: "Position regression", bookmark: Data(),
                             displayFilename: "position.epub", addedAt: Date()),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), player: player,
            preparedRenderer: renderer, preparedChapterStore: store,
            openStageObserver: { stage, _ in stages.record(stage) }, sessionDefaults: defaults,
            deferInitialReaderGestures: false)
        controller = reader
        window.rootViewController = reader
        window.makeKeyAndVisible()
        for _ in 0..<300 {
            await settle()
            if !reader.isLoadingBookContent, textView()?.text.isEmpty == false,
               !diskOpen || stages.catalogRead { break }
        }
        XCTAssertFalse(reader.isLoadingBookContent, "textFrame=\(String(describing: textView()?.frame))")
        XCTAssertTrue(!diskOpen || stages.catalogRead)
        await settle()
    }

    func close() {
        controller?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        controller = nil
    }

    func selectChapter(_ ordinal: Int) async throws {
        let reader = try XCTUnwrap(controller)
        // Exercise the actual table delegate and reader navigation callback.
        // Modal attachment/dismissal belongs to the real-app UI journey;
        // UIKit can defer presentation indefinitely in an isolated test window.
        if reader.presentedViewController == nil {
            reader.perform(NSSelectorFromString("presentTOC"))
        }
        let navigation = try XCTUnwrap(reader.presentedViewController as? UINavigationController)
        let table = try XCTUnwrap(navigation.topViewController as? UITableViewController)
        table.loadViewIfNeeded()
        guard table.tableView.numberOfRows(inSection: 0) > ordinal else {
            return XCTFail("The hydrated TOC must contain the requested chapter.")
        }
        table.tableView(table.tableView, didSelectRowAt: IndexPath(row: ordinal, section: 0))
        await settle()
        XCTAssertTrue(textView()?.text.hasPrefix("Chapter \(ordinal + 1).") == true)
        XCTAssertEqual(reader.currentReaderChapterIndex, ordinal)
        XCTAssertEqual(try offset(), 0, accuracy: 0.5)
    }

    func turn(forward: Bool) async throws {
        try XCTUnwrap(controller).perform(NSSelectorFromString(forward ? "turnPageRight" : "turnPageLeft"))
        await settle()
    }

    func offset() throws -> CGFloat {
        var ancestor = try XCTUnwrap(textView()).superview
        while ancestor != nil, !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        return try XCTUnwrap(ancestor as? UIScrollView).contentOffset.y
    }

    private func textView() -> UITextView? {
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return controller.flatMap { find($0.view) }
    }

    private func settle() async {
        window.layoutIfNeeded()
        controller?.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 20_000_000)
        window.layoutIfNeeded()
        controller?.view.layoutIfNeeded()
    }

    func cleanUp() {
        close()
        window.isHidden = true
        player.stop()
        LocalFulltextCache.evict(bookId: id)
        ReaderProgressStore.evict(bookId: id)
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        defaults.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: root)
        previousWindow?.makeKey()
    }
}
private final class PositionLoadStages: @unchecked Sendable {
    private let lock = NSLock()
    private var didReadCatalog = false

    func record(_ stage: String) {
        lock.lock()
        if stage == "prepared_fulltext_read_completed" { didReadCatalog = true }
        lock.unlock()
    }

    var catalogRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReadCatalog
    }
}
#endif
