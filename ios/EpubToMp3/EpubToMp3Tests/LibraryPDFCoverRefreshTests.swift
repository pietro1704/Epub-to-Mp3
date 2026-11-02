#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class LibraryPDFCoverRefreshTests: XCTestCase {
    func testOpeningLegacyPDFRefreshesOnlyCoverAndPersistsRevision() async throws {
        let fixture = try PDFCoverFixture()
        defer { fixture.cleanup() }
        let opened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        let updated = try XCTUnwrap(fixture.store.books.first)
        XCTAssertNotEqual(updated.coverPNG, fixture.book.coverPNG)
        XCTAssertNotNil(updated.coverPNG.flatMap(NSImage.init(data:)))
        XCTAssertEqual(updated.id, fixture.book.id)
        XCTAssertEqual(updated.title, fixture.book.title)
        XCTAssertEqual(updated.author, fixture.book.author)
        XCTAssertEqual(updated.tags, fixture.book.tags)
        XCTAssertEqual(updated.addedAt, fixture.book.addedAt)
        XCTAssertEqual(updated.lastChapterIndex, fixture.book.lastChapterIndex)
        XCTAssertEqual(updated.lastPositionSeconds, fixture.book.lastPositionSeconds)
        XCTAssertEqual(updated.lastJobId, fixture.book.lastJobId)
        XCTAssertEqual(updated.cachedOffline, fixture.book.cachedOffline)
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        try await fixture.store.flushPersistence()
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(fixture.defaults.data(forKey: "library"))) as? [[String: Any]])
        XCTAssertEqual(rows.first?["pdfCoverVersion"] as? Int, 1)
        let reloaded = LibraryStore(defaults: fixture.defaults, defaultsKey: "library")
        XCTAssertEqual(reloaded.books.first?.coverPNG, updated.coverPNG)
        var current = try XCTUnwrap(reloaded.books.first)
        current.coverPNG = Data("Keep the current-version cover".utf8)
        fixture.store.update(current)
        _ = try await fixture.store.openBookFileAsync(id: current.id)
        XCTAssertEqual(fixture.store.books.first?.coverPNG, current.coverPNG,
                       "Current rendering revisions must not be regenerated on each open")
        try await fixture.store.flushPersistence()
    }

    func testFailedPDFRenderKeepsOldCoverAndRetriesOnTheNextOpen() async throws {
        let fixture = try PDFCoverFixture(malformed: true)
        defer { fixture.cleanup() }
        let opened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertEqual(fixture.store.books.first?.coverPNG, fixture.book.coverPNG)
        XCTAssertNil(fixture.store.books.first?.pdfCoverVersion)
        let replacement = try PdfFixture.createSinglePage(title: "Recovered PDF")
        defer { try? FileManager.default.removeItem(at: replacement) }
        try Data(contentsOf: replacement).write(to: opened)
        _ = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertNotEqual(fixture.store.books.first?.coverPNG, fixture.book.coverPNG)
        XCTAssertEqual(fixture.store.books.first?.pdfCoverVersion, PdfMetadataReader.coverVersion)
        try await fixture.store.flushPersistence()
    }

    func testConcurrentCoverEditSurvivesBackgroundRefresh() async throws {
        let manager = PDFCoverCopyFileManager()
        let fixture = try PDFCoverFixture(manager: manager)
        defer { fixture.cleanup() }
        let editedCover = Data("User replacement during open".utf8)
        manager.onCopy = {
            XCTAssertFalse(Thread.isMainThread)
            let release = DispatchSemaphore(value: 0)
            Task { @MainActor in
                var edited = fixture.book
                edited.coverPNG = editedCover
                edited.pdfCoverVersion = PdfMetadataReader.coverVersion
                fixture.store.update(edited)
                release.signal()
            }
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        _ = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertEqual(fixture.store.books.first?.coverPNG, editedCover)
        try await fixture.store.flushPersistence()
    }

    func testCancelledPDFOpenDoesNotPublishRefreshedCover() async throws {
        try await verifyInvalidatedOpen(cancel: true)
    }

    func testReplacedBookmarkDoesNotReceiveObsoleteCover() async throws {
        try await verifyInvalidatedOpen(cancel: false)
    }

    func testNewPDFImportAlreadyRecordsTheCurrentCoverVersion() async throws {
        let fixture = try PDFCoverFixture()
        defer { fixture.cleanup() }
        fixture.store.remove(id: fixture.book.id)
        let imported = try await fixture.store.importBookAsync(from: fixture.source)
        XCTAssertEqual(imported.pdfCoverVersion, PdfMetadataReader.coverVersion)
        let prepared = try LibraryBookOpening.prepare(imported, fileManager: .default,
            importDirectory: fixture.root.appendingPathComponent("library"))
        XCTAssertNil(prepared.refreshedCover)
        try await fixture.store.flushPersistence()
    }

    func testVisibleDetailReceivesRefreshedCoverWithoutRecreation() async throws {
        guard ProcessInfo.processInfo.environment["EPUB_PDF_GUI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in visible PDF cover refresh acceptance")
        }
        let fixture = try PDFCoverFixture()
        defer { fixture.cleanup() }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage:
            UserDefaultsResumeStorage(defaults: fixture.defaults)))
        let controller = MacBookDetailViewController(book: fixture.book, library: fixture.store,
            settings: AppSettings(defaults: fixture.defaults), player: player,
            playerPresentation: PlayerPresentation(defaults: fixture.defaults), onRead: { _ in }, onShowJobs: {})
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 1000, height: 700)
        window.setContentSize(NSSize(width: 1000, height: 700))
        defer {
            player.stop()
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NSApp.setActivationPolicy(policy)
        }
        window.makeKeyAndOrderFront(nil)
        let activation = NSWorkspace.OpenConfiguration()
        activation.activates = true
        activation.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: activation)
        XCTAssertEqual(running.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        controller.view.layoutSubtreeIfNeeded()
        _ = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        let cover = try XCTUnwrap(fixture.store.books.first?.coverPNG)
        let expected = try XCTUnwrap(NSImage(data: cover)?.tiffRepresentation)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func showsRefreshedCover() -> Bool {
            descendants(controller.view).compactMap { $0 as? NSImageView }
                .contains { $0.visibleRect.height > 0 && $0.image?.tiffRepresentation == expected }
        }
        for _ in 0..<100 where !showsRefreshedCover() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(showsRefreshedCover(), "The original detail controller must receive the new cover")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "visible-legacy-pdf-cover-refreshed"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await fixture.store.flushPersistence()
    }

    private func verifyInvalidatedOpen(cancel: Bool) async throws {
        let manager = PDFCoverCopyFileManager()
        let fixture = try PDFCoverFixture(manager: manager)
        defer { fixture.cleanup() }
        let pending = PendingPDFOpen()
        manager.onCopy = {
            let release = DispatchSemaphore(value: 0)
            Task { @MainActor in
                if cancel { pending.task?.cancel() }
                else {
                    var replacement = fixture.book
                    replacement.bookmark = Data("Replacement identity".utf8)
                    fixture.store.update(replacement)
                }
                release.signal()
            }
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        pending.task = Task { try await fixture.store.openBookFileAsync(id: fixture.book.id) }
        do {
            _ = try await pending.task!.value
            XCTFail("Invalidated PDF preparation must not publish its cover")
        } catch {
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual((error as NSError).code, 409) }
        }
        XCTAssertEqual(fixture.store.books.first?.coverPNG, fixture.book.coverPNG)
        XCTAssertNil(fixture.store.books.first?.pdfCoverVersion)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        try await fixture.store.flushPersistence()
    }
}

@MainActor
private final class PendingPDFOpen { var task: Task<URL, Error>? }

private final class PDFCoverCopyFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    var onCopy: (@Sendable () -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    override func copyItem(at source: URL, to destination: URL) throws {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { callback = nil }
            return callback
        }
        action?()
        try super.copyItem(at: source, to: destination)
    }
}

@MainActor
private final class PDFCoverFixture {
    let suite = "pdf-cover-refresh-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let source: URL
    let sourceBytes: Data
    let book: BookEntity
    let store: LibraryStore

    init(manager: FileManager = .default, malformed: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        source = try PdfFixture.createSinglePage(title: "Source PDF", bodyText: "Original PDF text.")
        if malformed { try Data("Malformed PDF".utf8).write(to: source) }
        sourceBytes = try Data(contentsOf: source)
        book = BookEntity(id: try LibraryImportFiles.contentHash(of: source), title: "Retained title",
            author: "Retained author", bookmark: try LibraryBookmarkAccess.makeBookmark(for: source),
            displayFilename: source.lastPathComponent, addedAt: Date(timeIntervalSince1970: 1000),
            lastChapterIndex: 3, lastPositionSeconds: 42, coverPNG: Data("Previous cached cover".utf8),
            lastJobId: "retained-audio", cachedOffline: true, fileType: .pdf, tags: ["Retained tag"])
        // No rendering-version key: model the already persisted legacy schema.
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        store = LibraryStore(defaults: defaults, defaultsKey: "library", fileManager: manager,
                             importDirectory: root.appendingPathComponent("library"))
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
