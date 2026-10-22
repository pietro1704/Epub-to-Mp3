import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit
import AVFoundation
import CryptoKit

extension MacAppKitRootControllerTests {
    @MainActor
    func testReplacingWindowLimitedConversionAdmitsNewBookAndIgnoresRetiredCompletionAndFailure() async throws {
        for retiredFails in [false, true] {
            let id = "MacPlaybackReplacement.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
            let standard = UserDefaults.standard
            let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                        AudioPlayer.readerCurrentChapterIndexDefaultsKey]
            let saved = keys.map { standard.object(forKey: $0) }
            let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
            let savedWidgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
            let firstSource = try EpubFixture.createWithChapters(["First one", "First two", "First three", "First four"])
            let secondSource = try EpubFixture.createWithChapters(["Second one", "Second two", "Second three"])
            let first = try library.importBook(from: firstSource)
            let second = try library.importBook(from: secondSource)
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            var continuations: [AsyncStream<Void>.Continuation] = []
            var controls: [ConverterPlaybackControl] = []
            var jobs: [String] = []
            var retiredReturned = false
            let root = MacAppKitRootController(settings: AppSettings(defaults: defaults), library: library,
                player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
                playerPresentation: PlayerPresentation(defaults: defaults),
                conversionExecutor: { _, jobID, _, _, control, _, _, _, _ in
                    let position = jobs.count
                    jobs.append(jobID); controls.append(control)
                    var continuation: AsyncStream<Void>.Continuation!
                    let stream = AsyncStream<Void> { continuation = $0 }
                    continuations.append(continuation)
                    // Model a real worker held after it fills the two-chapter playback window.
                    for await _ in stream { }
                    if position == 0 {
                        retiredReturned = true
                        if retiredFails { throw CancellationError() }
                    }
                    let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                        "jobId": jobID, "title": "Fixture", "author": "Author", "chapters": [
                            ["sourceIndex": 0, "filename": "chapter.mp3", "title": "Chapter", "textChars": 50]]]])
                    return .init(jobID: jobID, manifestJSON: manifest, outputDirectory: directory)
                })
            defer {
                for continuation in continuations { continuation.finish() }
                NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio, object: nil)
                player.stop()
                for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
                widgetDefaults?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
                defaults.removePersistentDomain(forName: id)
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: firstSource)
                try? FileManager.default.removeItem(at: secondSource)
            }
            func wait(_ predicate: () -> Bool) async throws {
                for _ in 0..<200 {
                    if predicate() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTFail("Replacement conversion did not reach its expected state")
            }
            standard.set(first.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            standard.set(first.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
            standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
            _ = root.view
            root.startPlaybackForCurrentBook()
            try await wait { jobs.count == 1 }
            root.startPlaybackForCurrentBook()
            XCTAssertEqual(jobs.count, 1, "A repeated same-book Play must not start a replacement conversion")
            standard.set(second.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            root.startPlaybackForCurrentBook()
            try await wait { jobs.count == 2 }
            XCTAssertTrue(controls[0].isCancellationRequested)
            XCTAssertFalse(controls[1].isCancellationRequested)
            XCTAssertEqual(player.snapshot?.jobId, jobs[1])
            continuations[0].finish()
            try await wait { retiredReturned }
            await Task.yield()
            XCTAssertEqual(player.snapshot?.jobId, jobs[1])
            XCTAssertFalse(controls[1].isCancellationRequested,
                           "A retired failure/completion must not cancel the replacement control")
            XCTAssertNil(library.books.first(where: { $0.id == first.id })?.lastJobId,
                         "An invalidated completion must not record a stale playback job")
            NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio,
                                             object: nil, userInfo: ["bookID": first.id])
            XCTAssertFalse(controls[1].isCancellationRequested, "Storage removal of another book preserves playback")
            let external = try JSONDecoder().decode(JobSnapshot.self,
                from: Data(#"{"jobId":"external-owner","state":"running","bookTitle":"External owner"}"#.utf8))
            player.setSnapshot(external)
            XCTAssertTrue(controls[1].isCancellationRequested,
                          "A different playback owner must release the old window-limited worker")
            XCTAssertEqual(player.snapshot, external, "Retirement must not stop the replacement player")
            NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio, object: nil)
            XCTAssertNil(player.snapshot)
        }
    }

    @MainActor
    func testLocalConversionFinalizationPersistsJobAndKeepsCompleteProgressVisible() async throws {
        let suiteName = "MacConversionFinish.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let book = BookEntity(
            id: suiteName,
            title: "Conversion completion fixture",
            bookmark: Data([1]),
            displayFilename: "fixture.epub",
            addedAt: Date()
        )
        let libraryKey = "library.\(suiteName)"
        defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
        let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        let player = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))
        )
        let detail = MacBookDetailViewController(
            book: book,
            library: library,
            settings: AppSettings(defaults: defaults),
            player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            onRead: { _ in },
            onShowJobs: {}
        )
        let detailView = detail.view
        detailView.layoutSubtreeIfNeeded()

        let jobID = UUID().uuidString
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let manifestJSON = Data("""
        {"manifest":{"jobId":"\(jobID)","title":"Conversion completion fixture","author":"Test","chapters":[{"title":"Chapter 1","filename":"chapter.mp3","textChars":8000,"sourceIndex":0}],"cover":null}}
        """.utf8)
        let result = RustConversionCoordinator.Result(
            jobID: jobID,
            manifestJSON: manifestJSON,
            outputDirectory: outputDirectory
        )

        let snapshot = try detail.finalizeLocalConversion(result)

        XCTAssertTrue(snapshot.isTerminal)
        XCTAssertEqual(snapshot.chaptersCompleted, 1)
        XCTAssertEqual(library.books.first?.lastJobId, jobID)
        try await library.flushPersistence()
        let restoredLibrary = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        XCTAssertEqual(restoredLibrary.books.first?.lastJobId, jobID)

        func findProgressLabel(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField,
               label.accessibilityIdentifier() == "bookDetail.progress" {
                return label
            }
            return view.subviews.lazy.compactMap(findProgressLabel(in:)).first
        }
        let progressLabel = try XCTUnwrap(findProgressLabel(in: detailView))
        XCTAssertEqual(
            progressLabel.stringValue,
            L10n.string("bookDetail.progressPercent", 100)
        )
    }
}
#endif
