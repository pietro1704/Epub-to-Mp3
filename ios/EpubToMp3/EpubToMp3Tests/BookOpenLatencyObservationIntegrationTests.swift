#if os(iOS) || os(macOS)
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import XCTest

@testable import EpubToMp3

@MainActor
final class BookOpenLatencyObservationIntegrationTests: XCTestCase {
    func testOptInExistingEPUBColdWarmOpenLatencyAndMemory() async throws {
        let input = try NativePlaybackBenchmarkInput.optIn()
        var report = try NativePlaybackBenchmarkReport(input: input)
        let identifier = "NativeBookOpenBenchmark-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standard = UserDefaults.standard
        let keys = ["readerWarmBookIDs.v1", ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        var ownedIDs: [String] = []
        defer {
            for id in ownedIDs {
                LocalFulltextCache.evict(bookId: id)
                ReaderProgressStore.evict(bookId: id)
            }
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
            do { add(try report.attachment("native-existing-epub-open-benchmark.json")) }
            catch { XCTFail("Could not attach reader measurements: \(error)") }
        }
        for selection in input.books {
            // A fresh test-only identity gives a prepared-cache cold open
            // without deleting or warming the real imported book's cache.
            let id = UUID().uuidString
            ownedIDs.append(id)
            let url = URL(fileURLWithPath: selection.sourcePath)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let book = BookEntity(id: id, title: selection.name, bookmark: bookmark,
                                  displayFilename: url.lastPathComponent, addedAt: Date())
            let libraryKey = "library.\(id)"
            defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
            let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
            ReaderProgressStore.save(bookId: id, chapterIndex: selection.chapterStart, offsetFraction: 0)
            XCTAssertNil(LocalFulltextCache.inMemoryPayload(bookId: id))
            XCTAssertNil(LocalFulltextCache.read(bookId: id))
            report.points.append(.capture(book: selection.name, event: "before_cold_open",
                                          started: DispatchTime.now().uptimeNanoseconds))
            report.points.append(try await measuredOpen(book: book, library: library, defaults: defaults,
                                                        event: "prepared_cache_cold_open", cacheClass: .cold))
            for _ in 0..<200 {
                if LocalFulltextCache.inMemoryPayload(bookId: id) != nil,
                   let cache = LocalFulltextCache.storageURL(bookId: id),
                   FileManager.default.fileExists(atPath: cache.path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard LocalFulltextCache.inMemoryPayload(bookId: id) != nil else {
                throw NativePlaybackBenchmarkInput.invalid("Cold open did not prepare the process-warm reader cache")
            }
            let warm = try await measuredOpen(book: book, library: library, defaults: defaults,
                                              event: "process_warm_open", cacheClass: .inMemoryWarm)
            report.points.append(warm)
            XCTAssertLessThanOrEqual(warm.elapsedNanoseconds, 200_000_000,
                                     "Warm content and controls must become usable within 200 ms.")
        }
        report.status = "completed"
    }

    private func measuredOpen(
        book: BookEntity, library: LibraryStore, defaults: UserDefaults,
        event: String, cacheClass: LatencyObservation.CacheClass
    ) async throws -> NativePlaybackBenchmarkReport.Point {
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let started = DispatchTime.now().uptimeNanoseconds
        #if os(iOS)
        let controller = BookOpenScreenController(book: book, library: library,
            settings: AppSettings(defaults: defaults), bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "benchmark"),
            player: player)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; player.stop() }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #else
        UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let controller = MacReaderViewController(library: library,
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "benchmark"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close(); player.stop() }
        controller.view.layoutSubtreeIfNeeded()
        #endif
        for _ in 0..<3000 {
            let journeys = LatencyObservationStore.shared.snapshot().filter { !known.contains($0.id) && $0.kind == .bookOpen }
            if journeys.contains(where: { $0.records.contains { $0.transition == .controlsUsable } }) {
                guard journeys.contains(where: { $0.context.cacheClass == cacheClass
                    && $0.records.contains { $0.transition == .readableContent } }) else {
                    throw NativePlaybackBenchmarkInput.invalid("Observed cache class does not match the requested cold/warm case")
                }
                return .capture(book: book.title, event: event, started: started, journeys: journeys)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativePlaybackBenchmarkInput.invalid("Native reader readiness timed out; no latency success measured")
    }

    #if os(iOS)
    func testOpeningAnotherBookCancelsThePendingReaderJourney() throws {
        let identifier = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BookOpenLatencyObservationTests.\(identifier)"))
        defer { defaults.removePersistentDomain(forName: "BookOpenLatencyObservationTests.\(identifier)") }
        let firstBook = BookEntity(
            id: "pending-first-\(identifier)",
            title: "First pending book",
            bookmark: Data(),
            displayFilename: "first.epub",
            addedAt: Date()
        )
        let nextBook = BookEntity(
            id: "pending-next-\(identifier)",
            title: "Next book",
            bookmark: Data(),
            displayFilename: "next.epub",
            addedAt: Date()
        )
        let knownJourneyIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let controller = BookOpenScreenController(
            book: firstBook,
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(identifier)"),
            settings: AppSettings(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(identifier)"),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        )

        controller.loadViewIfNeeded()
        controller.update(book: nextBook)

        let journeys = LatencyObservationStore.shared.snapshot().filter { !knownJourneyIDs.contains($0.id) }
        XCTAssertTrue(
            journeys.contains { $0.records.map(\.transition) == [.openRequested, .cancelled] },
            "Changing books while the first reader journey is pending must cancel it."
        )
    }

    func testWarmBookOpenEmitsReaderJourney() throws {
        let identifier = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BookOpenLatencyObservationTests.\(identifier)"))
        let bookID = "latency-observation-\(identifier)"
        let book = BookEntity(
            id: bookID,
            title: "Latency test",
            bookmark: Data(),
            displayFilename: "latency-test.epub",
            addedAt: Date()
        )
        let payload = EbookFulltext(
            jobId: "latency-observation-job",
            bookTitle: nil,
            bookAuthor: nil,
            chapters: [
                .init(
                    index: 1,
                    name: "Chapter One",
                    text: String(repeating: "Readable test content. ", count: 20),
                    html: nil,
                    css: nil,
                    charCount: 460,
                    segments: nil
                ),
            ]
        )
        let knownJourneyIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        LocalFulltextCache.save(payload, bookId: bookID)
        defer {
            LocalFulltextCache.evict(bookId: bookID)
            defaults.removePersistentDomain(forName: "BookOpenLatencyObservationTests.\(identifier)")
        }

        let controller = BookOpenScreenController(
            book: book,
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(identifier)"),
            settings: AppSettings(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(identifier)"),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let journey = LatencyObservationStore.shared.snapshot().last(where: { !knownJourneyIDs.contains($0.id) }),
               journey.context.documentKind == .epub,
               journey.context.cacheClass == .inMemoryWarm,
               journey.records.map(\.transition) == [.openRequested, .readableContent, .controlsUsable] {
                XCTAssertEqual(
                    journey.records.map(\.elapsedNanoseconds),
                    journey.records.map(\.elapsedNanoseconds).sorted()
                )
                let exportedJourneys = try JSONDecoder().decode(
                    [LatencyObservation.Journey].self,
                    from: LatencyObservationStore.shared.exportData()
                )
                XCTAssertTrue(exportedJourneys.contains(where: { $0.id == journey.id }))
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTFail("The warm reader flow did not emit a completed latency observation.")
    }
    #endif
}
#endif
