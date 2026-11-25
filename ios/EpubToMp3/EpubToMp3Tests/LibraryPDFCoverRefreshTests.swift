#if os(macOS)
import AppKit
import PDFKit
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

    /// MAC-PDF-COVER-FLIPPED: a PDF imported before the upright renderer and
    /// never reopened kept its mirrored legacy cover in the library grid.
    func testShowingTheLibraryRefreshesLegacyPDFCoverWithoutOpeningTheBook() async throws {
        let fixture = try PDFCoverFixture()
        defer { fixture.cleanup() }
        let controller = MacLibraryViewController(library: fixture.store,
            bookmarkStore: BookmarkStore(defaults: fixture.defaults),
            onOpenBook: { _ in XCTFail("The library must not open the book") },
            onDownloadBook: { _ in }, onConvertBook: { _ in })
        _ = controller.view
        let deadline = Date().addingTimeInterval(10)
        while fixture.store.books.first?.pdfCoverVersion == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let updated = try XCTUnwrap(fixture.store.books.first)
        XCTAssertEqual(updated.pdfCoverVersion, PdfMetadataReader.coverVersion)
        XCTAssertNotEqual(updated.coverPNG, fixture.book.coverPNG)
        XCTAssertNotNil(updated.coverPNG.flatMap(NSImage.init(data:)))
        XCTAssertEqual(updated.bookmark, fixture.book.bookmark)
        XCTAssertNil(updated.lastOpenedAt, "Refreshing a cover is not opening the book")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("library").path),
                       "A cover refresh must not copy the source into the app library")
        try await fixture.store.flushPersistence()
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(fixture.defaults.data(forKey: "library"))) as? [[String: Any]])
        XCTAssertEqual(rows.first?["pdfCoverVersion"] as? Int, PdfMetadataReader.coverVersion)
    }

    /// Visual evidence for MAC-PDF-COVER-FLIPPED: the library first shows the
    /// stored legacy cover (the page mirrored vertically, as Pietro saw it) and
    /// then the upright cover regenerated without opening the book.
    func testLibraryScreenshotsShowMirroredLegacyCoverRegeneratedUpright() async throws {
        let fixture = try PDFCoverFixture(legacyCover: Self.mirroredFirstPage)
        defer { fixture.cleanup() }
        let controller = MacLibraryViewController(library: fixture.store,
            bookmarkStore: BookmarkStore(defaults: fixture.defaults),
            onOpenBook: { _ in XCTFail("The library must not open the book") },
            onDownloadBook: { _ in }, onConvertBook: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        // Assigning the controller shrinks the window to the view's fitting
        // size; give it a real library window size before capturing.
        window.setContentSize(NSSize(width: 900, height: 620))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        attachSnapshot(of: window, named: "mac-library-legacy-mirrored-cover")
        XCTAssertEqual(fixture.store.books.first?.coverPNG, fixture.book.coverPNG,
                       "The first capture must show the stored legacy cover")
        let deadline = Date().addingTimeInterval(10)
        while fixture.store.books.first?.pdfCoverVersion == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(fixture.store.books.first?.pdfCoverVersion, PdfMetadataReader.coverVersion)
        XCTAssertNotEqual(fixture.store.books.first?.coverPNG, fixture.book.coverPNG)
        try await Task.sleep(nanoseconds: 300_000_000)
        attachSnapshot(of: window, named: "mac-library-regenerated-upright-cover")
        window.contentViewController = nil
        try await fixture.store.flushPersistence()
    }

    nonisolated private static func mirroredFirstPage(_ source: URL) -> Data? {
        guard let page = PDFDocument(url: source)?.page(at: 0) else { return nil }
        let upright = page.thumbnail(of: NSSize(width: 300, height: 400), for: .mediaBox)
        let mirrored = NSImage(size: upright.size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: rect.height)
            transform.scaleX(by: 1, yBy: -1)
            transform.concat()
            upright.draw(in: rect)
            return true
        }
        guard let tiff = mirrored.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func attachSnapshot(of window: NSWindow, named name: String) {
        guard let content = window.contentView else { return XCTFail("The library window needs content") }
        XCTAssertGreaterThanOrEqual(content.bounds.width, 900, "The capture must show the library, not a collapsed window")
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return XCTFail("Snapshot bitmap unavailable")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("PNG encoding failed") }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testVisibleLibraryReceivesRefreshedCoverWithoutRecreation() async throws {
        guard ProcessInfo.processInfo.environment["EPUB_PDF_GUI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in visible PDF cover refresh acceptance")
        }
        let fixture = try PDFCoverFixture()
        defer { fixture.cleanup() }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let controller = MacLibraryViewController(library: fixture.store,
            bookmarkStore: BookmarkStore(defaults: fixture.defaults, storageKey: "bookmarks"),
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 1000, height: 700)
        window.setContentSize(NSSize(width: 1000, height: 700))
        defer {
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
        XCTAssertTrue(showsRefreshedCover(), "The existing library grid must receive the new cover")
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

    init(manager: FileManager = .default, malformed: Bool = false,
         legacyCover: ((URL) -> Data?)? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        source = try PdfFixture.createSinglePage(title: "Source PDF", bodyText: "Original PDF text.")
        if malformed { try Data("Malformed PDF".utf8).write(to: source) }
        sourceBytes = try Data(contentsOf: source)
        book = BookEntity(id: try LibraryImportFiles.contentHash(of: source), title: "Retained title",
            author: "Retained author", bookmark: try LibraryBookmarkAccess.makeBookmark(for: source),
            displayFilename: source.lastPathComponent, addedAt: Date(timeIntervalSince1970: 1000),
            lastChapterIndex: 3, lastPositionSeconds: 42,
            coverPNG: legacyCover?(source) ?? Data("Previous cached cover".utf8),
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
