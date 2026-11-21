#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class TocDownloadRefreshTests: XCTestCase {
    func testSharedContentsMapsReaderPositionsToSparseSourceChapterIndices() {
        let fulltext = EbookFulltext(jobId: "toc-sparse", bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Opening", text: "Opening", html: nil, css: nil, charCount: 7, segments: nil),
            .init(index: 7, name: "Sparse chapter", text: "Chapter", html: nil, css: nil, charCount: 7, segments: nil)
        ], toc: nil)
        let rows = [ReaderTocRow(title: "Part", level: 0, chapterIndex: nil),
                    ReaderTocRow(title: "Second position", level: 1, chapterIndex: 1)]
        let canonical = ReaderContentsPresentation.sourceRows(rows, fulltext: fulltext)
        XCTAssertEqual(canonical.map(\.chapterIndex), [nil, 6])
        XCTAssertEqual(canonical.map(\.level), [0, 1])
    }

    func testSourceChapterCanRequestOfflineAudioBeforeAnySnapshotContainsIt() throws {
        let book = BookEntity(id: "toc-text-only", title: "Text Only", bookmark: Data(),
                              displayFilename: "text-only.epub", addedAt: Date())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "toc-\(UUID().uuidString)"))
        let library = LibraryStore(defaults: defaults)
        let navigation = ReaderContentsPresentation.makeSheet(book: book, rows: [
            ReaderTocRow(title: "Part", level: 0, chapterIndex: nil),
            ReaderTocRow(title: "Sparse chapter", level: 1, chapterIndex: 6)
        ], library: library, settings: AppSettings(), snapshot: nil, playingIndex: nil,
           readingIndex: 6, onSelect: { _ in })
        let toc = try XCTUnwrap(navigation.viewControllers.first as? TocScreenController)
        toc.loadViewIfNeeded()
        let heading = toc.tableView(toc.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertNil(heading.accessoryView)
        let chapter = toc.tableView(toc.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        let download = try XCTUnwrap(chapter.accessoryView as? UIButton)
        XCTAssertTrue(download.isEnabled)
        XCTAssertEqual(download.accessibilityIdentifier, "reader.toc.download.6")
        XCTAssertEqual(chapter.indentationLevel, 1)
    }

    func testVisibleDownloadAccessoryUpdatesAfterActualRetainedDownload() async throws {
        try await assertRetainedDownloadInContents(sharedBookContents: false)
    }

    func testSharedBookContentsPublishesDownloadInFiles() async throws {
        try await assertRetainedDownloadInContents(sharedBookContents: true)
    }

    func testSharedContentsRemovesFilesCopiesWithoutPlaybackSnapshot() async throws {
        let bookID = "toc-withdraw-\(UUID().uuidString)"
        let book = BookEntity(id: bookID, title: bookID, bookmark: Data(),
                              displayFilename: "test.epub", addedAt: Date())
        let suite = "toc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let library = LibraryStore(defaults: defaults)
        let settings = AppSettings()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(bookID).mp3")
        let bytes = Data("Offline chapter fixture".utf8)
        let store = LocalAudioArtifactStore.shared
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? await store.removeAllAudio(bookID: bookID)
            try? FileManager.default.removeItem(at: source)
        }
        try bytes.write(to: source)
        for index in 0...1 {
            _ = try await store.retainDownload(from: source, request: .init(
                bookID: bookID, bookTitle: book.title, author: nil,
                chapterIndex: index, chapterTitle: "Chapter \(index + 1)"), requireVisibleCopy: true)
        }
        try FileManager.default.removeItem(at: source)
        let files = try XCTUnwrap(DownloadedAudioFilesMirror.userVisible?.root)
            .appendingPathComponent(book.title, isDirectory: true)
        let firstCopy = files.appendingPathComponent("01 - Chapter 1.mp3")
        let secondCopy = files.appendingPathComponent("02 - Chapter 2.mp3")
        XCTAssertEqual(try Data(contentsOf: firstCopy), bytes)
        XCTAssertEqual(try Data(contentsOf: secondCopy), bytes)

        let navigation = ReaderContentsPresentation.makeSheet(book: book, rows: [
            ReaderTocRow(title: "Chapter 1", level: 0, chapterIndex: 0),
            ReaderTocRow(title: "Chapter 2", level: 0, chapterIndex: 1)
        ], library: library, settings: settings, snapshot: nil,
            playingIndex: nil, readingIndex: nil, onSelect: { _ in })
        let controller = try XCTUnwrap(navigation.topViewController as? TocScreenController)
        let (window, previousWindow) = try showContents(navigation)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let indexPath = IndexPath(row: 0, section: 0)
        let removeLabel = L10n.string("toc.removeDownload")
        let downloadLabel = L10n.string("player.downloadChapter")
        let downloaded = try await waitForVisibleChapter(in: controller, window: window, at: indexPath) {
            $0.accessoryView?.accessibilityLabel == removeLabel
        }
        XCTAssertTrue(downloaded, "The visible chapter must offer removal after publishing its MP3.")
        let downloads = ReaderChapterDownloads(book: book, library: library, settings: settings, snapshot: nil)
        await downloads.remove(chapter: 0)
        let returnedToDownload = try await waitForVisibleChapter(in: controller, window: window, at: indexPath) {
            $0.accessoryView?.accessibilityLabel == downloadLabel
        }
        XCTAssertTrue(returnedToDownload, "The visible chapter must offer Download again after removing its Files copy.")
        let remaining = try await store.downloadedChapterIndicesInFiles(bookID: bookID)
        XCTAssertEqual(remaining, [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCopy.path))
        XCTAssertEqual(try Data(contentsOf: secondCopy), bytes)
        await downloads.remove(chapter: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCopy.path))
        let published = try await store.downloadedChapterIndicesInFiles(bookID: bookID)
        XCTAssertTrue(published.isEmpty)
        let retained = try await store.downloadedChapterIndices(bookID: bookID)
        XCTAssertEqual(retained, [0, 1])
        for index in retained {
            let canonical = try await store.canonicalURL(bookID: bookID, chapterIndex: index)
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
        }
    }

    private func assertRetainedDownloadInContents(sharedBookContents: Bool) async throws {
        // A snapshot of the book's own kept audio names its book in the job id.
        let fixtureID = "toc-download-\(UUID().uuidString)"
        let sharedFixture = try (sharedBookContents ? importDownloadFixture(named: fixtureID) : nil)
        let bookID = sharedFixture?.book.id ?? fixtureID
        let jobID = "embedded-\(bookID)"
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(jobID).mp3")
        // Valid mono 24 kHz MP3 shared with the Rust fixture suite.
        let bytes = try XCTUnwrap(Data(base64Encoded: "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"))
        try bytes.write(to: source)
        addTeardownBlock {
            try? await LocalAudioArtifactStore.shared.removeAllAudio(bookID: bookID)
            try? FileManager.default.removeItem(at: source)
        }
        let chapter = JobSnapshot.Chapter(index: 0, name: "Download fixture", status: "completed",
            downloadUrl: source.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
            durationSeconds: nil, startedAt: nil, completedAt: nil)
        let snapshot = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Download fixture",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil,
            language: nil, progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [chapter], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil,
            chapterIndexBase: 0)
        let controller: TocScreenController
        let root: UIViewController
        if let sharedFixture {
            let navigation = ReaderContentsPresentation.makeSheet(
                book: sharedFixture.book, rows: [ReaderTocRow(title: "Download fixture", level: 0, chapterIndex: 0)],
                library: sharedFixture.library, settings: AppSettings(),
                snapshot: snapshot, playingIndex: 0, readingIndex: nil, onSelect: { _ in })
            controller = try XCTUnwrap(navigation.topViewController as? TocScreenController)
            root = navigation
        } else {
            controller = TocScreenController(fulltext: nil, snapshot: snapshot,
                currentChapterIndex: 0, readingChapterIndex: nil, onJump: { _ in },
                onDownload: { index in
                    Task {
                        await AudiobookDownloads.shared.enqueueSelected(snapshot: snapshot,
                            epubZeroBasedIndices: [index], baseURL: nil)
                    }
                }, onRemoveDownload: { _ in }, onDownloadAll: nil,
                onCancelDownloads: nil, onClearDownloads: nil)
            root = controller
        }
        let (window, previousWindow) = try showContents(root)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let indexPath = IndexPath(row: 0, section: 0)
        XCTAssertTrue(controller.view.window === window && window.isKeyWindow)
        let button = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath)?.accessoryView as? UIButton)
        XCTAssertNil(button.accessibilityValue)
        XCTAssertTrue(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        if sharedBookContents {
            XCTAssertEqual(controller.navigationItem.prompt, L10n.string("toc.audioPreparing"),
                           "The Download button must start the chapter request.")
        }
        let downloadedStatus = L10n.string("toc.downloaded")
        _ = try await waitForVisibleChapter(in: controller, window: window, at: indexPath) {
            $0.accessoryView?.accessibilityValue == downloadedStatus && $0.accessibilityValue == downloadedStatus
                && (!sharedBookContents || controller.navigationItem.prompt == nil)
        }
        if sharedBookContents {
            let alert = controller.presentedViewController as? UIAlertController
            XCTAssertNil(alert?.message, "The chapter request must succeed.")
            XCTAssertNil(controller.navigationItem.prompt, "The chapter request must finish within the test window.")
        }
        let kept = try await LocalAudioArtifactStore.shared.downloadedChapterIndices(bookID: bookID)
        XCTAssertEqual(kept, [0], "The completed chapter must be retained.")
        if let sharedFixture {
            let published = try await LocalAudioArtifactStore.shared.downloadedChapterIndicesInFiles(bookID: bookID)
            XCTAssertEqual(published, [0], "The retained chapter must be published in Files.")
            if let documents = DownloadedAudioFilesMirror.userVisible?.root {
                let mirror = documents.appendingPathComponent(sharedFixture.book.resolvedTitle, isDirectory: true)
                    .appendingPathComponent("01 - Download fixture.mp3")
                XCTAssertEqual(try Data(contentsOf: mirror), bytes, "Files must contain the completed MP3 bytes.")
            } else {
                XCTFail("The app must expose a Files mirror for downloaded audio.")
            }
        }
        XCTAssertNil(AudiobookDownloadStorage.loadManifest(for: jobID), "A Download must not write the previous layout")
        do {
            let retained = try await LocalAudioArtifactStore.shared.canonicalURL(bookID: bookID, chapterIndex: 0)
            XCTAssertEqual(try Data(contentsOf: retained), bytes, "The retained MP3 must keep the source bytes.")
        } catch {
            XCTFail("The retained MP3 must be readable: \(error)")
        }
        let visibleCell = controller.tableView.cellForRow(at: indexPath)
        XCTAssertNotNil(visibleCell, "The chapter row must remain visible after its Download state changes.")
        XCTAssertEqual(visibleCell?.accessibilityValue, downloadedStatus, "Chapter row status")
        XCTAssertEqual(visibleCell?.accessoryView?.accessibilityValue, downloadedStatus,
                       "Download button status")
    }

    private func importDownloadFixture(named name: String) throws -> (book: BookEntity, library: LibraryStore) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let encodedBook = try EpubFixture.createWithChapters(["Download fixture \(name)."])
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: encodedBook)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = LibraryStore(defaults: defaults, importDirectory: directory)
        var book = try library.importBook(from: encodedBook)
        book.title = name
        library.update(book)
        try library.flushPersistenceSync()
        XCTAssertFalse(book.bookmark.isEmpty, "The imported EPUB must have a usable library bookmark.")
        XCTAssertTrue(library.books.contains { $0.id == book.id }, "The download fixture must belong to its library.")
        return (book, library)
    }

    private func showContents(_ root: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive },
            "Visible chapter status requires the app's foreground scene.")
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        return (window, previousWindow)
    }

    private func waitForVisibleChapter(in controller: TocScreenController, window: UIWindow, at indexPath: IndexPath,
                                       matching predicate: (UITableViewCell) -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            window.layoutIfNeeded()
            controller.tableView.layoutIfNeeded()
            if let cell = controller.tableView.cellForRow(at: indexPath), predicate(cell) { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}
#endif
