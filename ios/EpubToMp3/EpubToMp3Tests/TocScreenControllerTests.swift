#if os(iOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class TocScreenControllerTests: XCTestCase {
    func testAvailableChapterUsesDirectDownloadAccessoryAction() {
        var requestedChapter: Int?
        let controller = TocScreenController(
            fulltext: nil,
            snapshot: snapshot(),
            currentChapterIndex: -1,
            readingChapterIndex: nil,
            onJump: { _ in },
            onDownload: { requestedChapter = $0 },
            onDownloadAll: nil,
            onCancelDownloads: nil,
            onClearDownloads: nil
        )

        controller.loadViewIfNeeded()
        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        guard let button = cell.accessoryView as? UIButton else {
            return XCTFail("An available chapter must expose a download accessory.")
        }

        XCTAssertEqual(button.accessibilityIdentifier, "reader.toc.download.4")
        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(requestedChapter, 4)
    }

    func testDownloadAccessoryUsesCellManagedLayout() {
        let controller = TocScreenController(
            fulltext: nil,
            snapshot: snapshot(),
            currentChapterIndex: -1,
            readingChapterIndex: nil,
            onJump: { _ in },
            onDownload: { _ in },
            onDownloadAll: nil,
            onCancelDownloads: nil,
            onClearDownloads: nil
        )

        controller.loadViewIfNeeded()
        let cell = controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        let button = try? XCTUnwrap(cell.accessoryView as? UIButton)

        XCTAssertTrue(
            button?.translatesAutoresizingMaskIntoConstraints == true,
            "UITableViewCell must position chapter download accessories in its trailing accessory slot."
        )
    }

    func testExportAffordanceAppearsInTheSharedTocMenu() {
        let controller = TocScreenController(
            fulltext: nil,
            snapshot: snapshot(),
            currentChapterIndex: -1,
            readingChapterIndex: nil,
            onJump: { _ in },
            onDownload: nil,
            onDownloadAll: nil,
            onCancelDownloads: nil,
            onClearDownloads: nil,
            onExport: {}
        )

        controller.loadViewIfNeeded()
        let actions = controller.navigationItem.leftBarButtonItem?.menu?.children.compactMap {
            $0 as? UIAction
        } ?? []

        XCTAssertTrue(actions.contains { $0.title == L10n.string("player.exportAudio") })
    }

    func testPendingArtifactUsesTheBookLevelQueueStatus() {
        XCTAssertTrue(
            TocScreenController.usesSchedulerStatus(
                artifactState: .pending,
                schedulerState: .waitingForWiFi
            )
        )
        XCTAssertTrue(
            TocScreenController.usesSchedulerStatus(
                artifactState: nil,
                schedulerState: .queued
            )
        )
        XCTAssertFalse(
            TocScreenController.usesSchedulerStatus(
                artifactState: .generating,
                schedulerState: .waitingForWiFi
            )
        )
    }

    func testEmbeddedTocReleasesItsNotificationObservers() async {
        weak var releasedController: TocScreenController?

        autoreleasepool {
            let controller = TocScreenController(
                fulltext: nil,
                snapshot: snapshot(jobID: "embedded-book-id"),
                currentChapterIndex: -1,
                readingChapterIndex: nil,
                onJump: { _ in },
                onDownload: nil,
                onDownloadAll: nil,
                onCancelDownloads: nil,
                onClearDownloads: nil
            )
            controller.loadViewIfNeeded()
            releasedController = controller
        }

        await Task.yield()

        XCTAssertNil(releasedController)
    }

    private func snapshot(jobID: String = "remote-job") -> JobSnapshot {
        JobSnapshot(
            jobId: jobID,
            state: "finished",
            bookTitle: "Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: "voice",
            language: "en",
            progressPercent: 100,
            chaptersTotal: 1,
            chaptersCompleted: 1,
            chapterProgress: [
                .init(
                    index: 4,
                    name: "Chapter Five",
                    status: "completed",
                    downloadUrl: "file:///chapter-4.mp3",
                    chars: 100,
                    charsProcessed: 100,
                    progressRatio: 1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}
#endif
