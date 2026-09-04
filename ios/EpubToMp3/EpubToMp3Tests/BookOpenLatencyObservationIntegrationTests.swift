#if os(iOS)
import UIKit
import XCTest

@testable import EpubToMp3

@MainActor
final class BookOpenLatencyObservationIntegrationTests: XCTestCase {
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
}
#endif
