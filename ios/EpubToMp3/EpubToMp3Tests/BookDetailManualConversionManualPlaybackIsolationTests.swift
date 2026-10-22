#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
#if os(macOS)
import AppKit
#endif

@testable import EpubToMp3

extension BookDetailManualConversionTests {
    func testManualCompletionAfterExplicitAudioRemovalDoesNotRestoreDeletedJob() async throws {
        let id = "detail-removed-conversion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let source = try EpubFixture.createWithChapter(body: "A conversion cancelled by explicit storage removal.")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let started = expectation(description: "Manual conversion is waiting for output")
        var release: AsyncStream<Void>.Continuation!
        let completion = AsyncStream<Void> { release = $0 }
        var returned = false
        var capturedProgress: (@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?
        var requestedJob: String?
        let executor: RustConversionCoordinator.Executor = { _, jobID, _, _, _, progress, _ in
            requestedJob = jobID
            capturedProgress = progress
            started.fulfill()
            for await _ in completion { }
            let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": jobID, "title": "Removed conversion", "author": "Author", "chapters": []]])
            returned = true
            return .init(jobID: jobID, manifestJSON: manifest, outputDirectory: directory)
        }
        defer {
            release.finish()
            player.stop()
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        #if os(iOS)
        let controller = BookDetailScreenController(book: book, library: library,
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: presentation, conversionExecutor: executor)
        controller.loadViewIfNeeded()
        controller.downloadWholeBook()
        #else
        let controller = MacBookDetailViewController(book: book, library: library,
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: presentation, onRead: { _ in }, onShowJobs: {}, conversionExecutor: executor)
        _ = controller.view
        controller.convertWholeBook(options: AppSettings(defaults: defaults).conversionOptions)
        #endif
        await fulfillment(of: [started], timeout: 3)
        let jobID = try XCTUnwrap(requestedJob)
        NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio,
                                         object: nil, userInfo: ["bookID": book.id])
        capturedProgress?(.init(jobId: jobID, state: "running", chapterIndex: 0, chaptersTotal: 1,
            chaptersCompleted: 1, percent: 100, engine: "piper", message: "Late progress"))
        release.finish()
        for _ in 0..<100 where !returned { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(returned)
        await Task.yield()
        await Task.yield()
        XCTAssertNil(library.books.first(where: { $0.id == book.id })?.lastJobId,
                     "An output removed while conversion was pending must not be recorded again")
        try await library.flushPersistence()
        let reloaded = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        XCTAssertNil(reloaded.books.first(where: { $0.id == book.id })?.lastJobId)
        XCTAssertNil(player.snapshot)
        #if os(iOS)
        XCTAssertNil(controller.presentedViewController)
        #else
        XCTAssertNil(NSApp.modalWindow)
        #endif
        withExtendedLifetime(controller) { }
    }

    func testManualCompletionPreservesExistingPlaybackSession() async throws {
        try await verifyManualConversion(existingSession: true)
    }

    func testManualCompletionDoesNotCreatePlaybackSession() async throws {
        try await verifyManualConversion(existingSession: false)
    }
}
#endif
