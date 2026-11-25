#if os(iOS)
import XCTest
@testable import EpubToMp3

final class TocScreenControllerTests: XCTestCase {
    @MainActor
    func testChapterSelectionPolicyLeavesItsDownloadAccessoryIndependent() throws {
        var selected: [Int] = []
        var downloads: [Int] = []
        let rows = [
            ReaderTocRow(title: "Missing audio", level: 0, chapterIndex: 1),
            ReaderTocRow(title: "Playable audio", level: 0, chapterIndex: 4)
        ]
        let controller = TocScreenController(fulltext: nil, snapshot: snapshot(),
            currentChapterIndex: -1, readingChapterIndex: nil,
            onJump: { selected.append($0) }, onDownload: { downloads.append($0) },
            onDownloadAll: nil, onCancelDownloads: nil, onClearDownloads: nil,
            sourceRows: rows, downloadBookID: "selection-fixture",
            canSelectChapter: { $0 == 4 })
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.tableView)
        let unavailable = IndexPath(row: 0, section: 0)
        let playable = IndexPath(row: 1, section: 0)

        XCTAssertNil(controller.tableView(table, willSelectRowAt: unavailable))
        controller.tableView(table, didSelectRowAt: unavailable)
        XCTAssertTrue(selected.isEmpty)
        let cell = controller.tableView(table, cellForRowAt: unavailable)
        XCTAssertEqual(cell.accessibilityValue, L10n.string("toc.textOnly"))
        let download = try XCTUnwrap(cell.accessoryView as? UIButton)
        XCTAssertEqual(download.accessibilityIdentifier, "reader.toc.download.1")
        XCTAssertTrue(download.isEnabled)
        download.sendActions(for: .touchUpInside)
        XCTAssertEqual(downloads, [1])

        XCTAssertEqual(controller.tableView(table, willSelectRowAt: playable), playable)
        controller.tableView(table, didSelectRowAt: playable)
        XCTAssertEqual(selected, [4])
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
    func testPendingArtifactUsesTheBookLevelQueueStatus() {
        XCTAssertTrue(
            TocChapterPresentation.usesSchedulerStatus(
                artifactState: .pending,
                schedulerState: .waitingForWiFi
            )
        )
        XCTAssertTrue(
            TocChapterPresentation.usesSchedulerStatus(
                artifactState: nil,
                schedulerState: .queued
            )
        )
        XCTAssertFalse(
            TocChapterPresentation.usesSchedulerStatus(
                artifactState: .generating,
                schedulerState: .waitingForWiFi
            )
        )
    }

    @MainActor
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
