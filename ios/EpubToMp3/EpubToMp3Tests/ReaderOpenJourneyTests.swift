import XCTest

@testable import EpubToMp3

/// The open-journey state machine shared by the iOS and Mac readers. It runs on
/// both platforms: it touches no UI type, only `LatencyObservationStore`.
@MainActor
final class ReaderOpenJourneyTests: XCTestCase {
    private func book(_ type: BookFileType, id: String = UUID().uuidString) -> BookEntity {
        BookEntity(
            id: id, title: "Journey", bookmark: Data([1]),
            displayFilename: "journey.\(type == .pdf ? "pdf" : "epub")", addedAt: Date(), fileType: type
        )
    }

    private func journey(_ id: UUID) -> LatencyObservation.Journey? {
        LatencyObservationStore.shared.snapshot().first { $0.id == id }
    }

    private func transitions(_ id: UUID) -> [LatencyObservation.Transition]? {
        journey(id)?.records.map(\.transition)
    }

    private final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func append(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    func testEpubJourneyFinishesAtUsableControlsAndEmitsTheStages() throws {
        let stages = StageLog()
        let open = ReaderOpenJourney()
        open.stageObserver = { name, _ in stages.append(name) }
        let id = open.begin(for: book(.epub))
        XCTAssertEqual(open.activeBookOpenJourneyID, id)
        XCTAssertEqual(journey(id)?.context.documentKind, .epub)

        open.recordReadableContent()
        open.recordControlsUsable()

        XCTAssertEqual(transitions(id), [.openRequested, .readableContent, .controlsUsable])
        XCTAssertEqual(stages.recorded, ["readable_content", "controls_usable"])
        XCTAssertNil(open.activeBookOpenJourneyID, "An EPUB journey ends at usable controls.")
    }

    func testPDFJourneyFinishesOnlyAfterTheFirstPageAndUsableControls() throws {
        let open = ReaderOpenJourney()
        let id = open.begin(for: book(.pdf))
        XCTAssertEqual(journey(id)?.context.documentKind, .selectableTextPDF)
        open.pendingPDFPageJourneyID = id

        open.recordControlsUsable()
        XCTAssertEqual(open.activeBookOpenJourneyID, id, "Controls alone must not finish a PDF journey.")
        XCTAssertEqual(open.controlsReadyJourneyID, id)

        open.recordFirstPDFPage(wasNormalized: false)

        XCTAssertNil(open.activeBookOpenJourneyID)
        XCTAssertNil(open.pendingPDFPageJourneyID)
        XCTAssertNil(open.firstPDFPageReadyJourneyID)
        XCTAssertNil(open.controlsReadyJourneyID)
        let recorded = try XCTUnwrap(transitions(id))
        XCTAssertTrue(recorded.contains(.firstPDFPage))
        XCTAssertTrue(recorded.contains(.controlsUsable))
    }

    func testPDFFirstPageBeforeControlsAlsoFinishesTheJourneyOnce() throws {
        let open = ReaderOpenJourney()
        let id = open.begin(for: book(.pdf))
        open.pendingPDFPageJourneyID = id

        open.recordFirstPDFPage(wasNormalized: true)
        XCTAssertEqual(open.activeBookOpenJourneyID, id, "The first page alone must not finish the journey.")
        XCTAssertEqual(journey(id)?.context.documentKind, .normalizedScannedPDF)

        open.recordControlsUsable()
        XCTAssertNil(open.activeBookOpenJourneyID)
    }

    func testFirstPDFPageIsIgnoredWithoutAPendingPageForTheActiveJourney() throws {
        let open = ReaderOpenJourney()
        let id = open.begin(for: book(.pdf))

        open.recordFirstPDFPage(wasNormalized: false)

        XCTAssertEqual(transitions(id), [.openRequested])
        XCTAssertNil(open.firstPDFPageReadyJourneyID)
    }

    func testCancelRecordsCancellationAndClearsEveryIdentifier() throws {
        let open = ReaderOpenJourney()
        let id = open.begin(for: book(.pdf))
        open.pendingPDFPageJourneyID = id
        open.firstPDFPageReadyJourneyID = id
        open.controlsReadyJourneyID = id

        open.cancelActiveBookOpenJourney()

        XCTAssertEqual(transitions(id), [.openRequested, .cancelled])
        XCTAssertNil(open.activeBookOpenJourneyID)
        XCTAssertNil(open.pendingPDFPageJourneyID)
        XCTAssertNil(open.firstPDFPageReadyJourneyID)
        XCTAssertNil(open.controlsReadyJourneyID)
    }

    func testStepsWithoutAnActiveJourneyRecordNothing() throws {
        let stages = StageLog()
        let open = ReaderOpenJourney()
        open.stageObserver = { name, _ in stages.append(name) }
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))

        open.recordReadableContent()
        open.recordControlsUsable()
        open.cancelActiveBookOpenJourney()

        XCTAssertEqual(stages.recorded, [])
        XCTAssertEqual(Set(LatencyObservationStore.shared.snapshot().map(\.id)), known)
    }

    func testReleasingTheOwnerCancelsAnActiveJourney() throws {
        var open: ReaderOpenJourney? = ReaderOpenJourney()
        let id = try XCTUnwrap(open?.begin(for: book(.epub)))

        open = nil

        XCTAssertEqual(transitions(id), [.openRequested, .cancelled])
    }

    func testBeginningAgainMakesTheNewJourneyTheActiveOne() throws {
        let open = ReaderOpenJourney()
        let first = open.begin(for: book(.epub))
        let second = open.begin(for: book(.epub))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(open.activeBookOpenJourneyID, second)
    }
}
