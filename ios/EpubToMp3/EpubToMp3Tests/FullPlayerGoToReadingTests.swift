#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// PLAYER-GO-TO-READING-PAGE: the filled "Go to reading" button sits right of the speed button, shows only when
/// reader and narration have diverged, and opens the reader at the narrated sentence.
@MainActor
final class FullPlayerGoToReadingTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(descendants) }

    private func makeController(suite: String) throws -> (FullPlayerScreenController, AudioPlayer, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let book = BookEntity(id: "go-reading-book", title: "Book", bookmark: Data([1]),
                              displayFilename: "book.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")
        // The player reads its location from the resume store's defaults, not from `.standard`.
        defaults.set(book.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        player.setSnapshot(JobSnapshot(
            jobId: "job", state: "running", bookTitle: "Book", bookAuthor: nil, coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil, progressPercent: nil, chaptersTotal: 1, chaptersCompleted: nil,
            chapterProgress: [], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil))
        let controller = FullPlayerScreenController(player: player,
            library: LibraryStore(defaults: defaults, defaultsKey: "library.books.v1"), playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: {})
        controller.loadViewIfNeeded()
        return (controller, player, defaults)
    }

    func testButtonAppearsWhenDivergedHidesWhenPairedAndOpensTheNarratedSentence() throws {
        let suite = "go-to-reading-\(UUID().uuidString)"
        let (controller, player, defaults) = try makeController(suite: suite)
        defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        var opened: [String] = []
        controller.onOpenReaderAtPlayback = { opened.append($0) }
        let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
        let goTo = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "fullPlayer.goToReading" })
        let rate = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "fullPlayer.playbackRateButton" })

        // Transport state is committed on a later main-queue turn.
        let committed = expectation(description: "transport state committed")
        DispatchQueue.main.async { committed.fulfill() }
        wait(for: [committed], timeout: 2)
        controller.refresh(library: LibraryStore(defaults: defaults, defaultsKey: "library.books.v1"))
        XCTAssertFalse(goTo.isHidden, "Diverged (default) reader: the button is offered")
        XCTAssertEqual(goTo.accessibilityLabel, L10n.string("player.goToReading"))
        XCTAssertNotNil(goTo.configuration?.background.backgroundColor ?? goTo.configuration?.baseBackgroundColor ?? .tintColor,
                        "The button is the filled, prominent style")
        controller.view.layoutIfNeeded()
        let stack = try XCTUnwrap(goTo.superview as? UIStackView)
        XCTAssertTrue(stack === rate.superview)
        XCTAssertEqual(stack.arrangedSubviews.firstIndex(of: goTo), (stack.arrangedSubviews.firstIndex(of: rate) ?? -2) + 1,
                       "Right of the speed button")

        goTo.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, ["go-reading-book"], "Tapping goes to the narrated sentence of the playing book")

        player.readerPairing.publish(paired: true)
        let hidden = expectation(description: "hidden when paired")
        DispatchQueue.main.async { hidden.fulfill() }
        wait(for: [hidden], timeout: 2)
        XCTAssertTrue(goTo.isHidden, "Paired: reader already shows the narrated passage")

        player.readerPairing.publish(paired: false)
        let shown = expectation(description: "shown again")
        DispatchQueue.main.async { shown.fulfill() }
        wait(for: [shown], timeout: 2)
        XCTAssertFalse(goTo.isHidden)
    }
}
#endif
