#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class TocDownloadRefreshTests: XCTestCase {
    func testVisibleDownloadAccessoryUpdatesAfterActualRetainedDownload() async throws {
        let jobID = "toc-download-\(UUID().uuidString)"
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(jobID).mp3")
        // Valid mono 24 kHz MP3 shared with the Rust fixture suite.
        let bytes = try XCTUnwrap(Data(base64Encoded: "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"))
        try bytes.write(to: source)
        defer {
            DownloadManager.deleteAudiobook(jobId: jobID)
            try? FileManager.default.removeItem(at: source)
        }
        let chapter = JobSnapshot.Chapter(index: 0, name: "Download fixture", status: "completed",
            downloadUrl: source.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
            durationSeconds: nil, startedAt: nil, completedAt: nil)
        let snapshot = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Download fixture",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil,
            language: nil, progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [chapter], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        let controller = TocScreenController(fulltext: nil, snapshot: snapshot,
            currentChapterIndex: 0, readingChapterIndex: nil, onJump: { _ in },
            onDownload: { index in
                Task {
                    await DownloadManager.shared.enqueueSelected(snapshot: snapshot,
                        epubZeroBasedIndices: [index], baseURL: nil)
                }
            }, onRemoveDownload: { _ in }, onDownloadAll: nil,
            onCancelDownloads: nil, onClearDownloads: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.isHidden = false
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
        }
        let indexPath = IndexPath(row: 0, section: 0)
        let button = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath)?.accessoryView as? UIButton)
        XCTAssertNil(button.accessibilityValue)
        XCTAssertTrue(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let cell = controller.tableView.cellForRow(at: indexPath)
            return (cell?.accessoryView as? UIButton)?.accessibilityValue == L10n.string("toc.downloaded")
                && cell?.accessibilityValue == L10n.string("toc.downloaded")
        }, object: nil)
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(DownloadManager.locallyDownloadedIndices(for: jobID), [0])
        let manifest = try XCTUnwrap(DownloadManager.loadManifest(for: jobID))
        let entry = try XCTUnwrap(manifest.chapters.first)
        XCTAssertEqual(entry.index, 0)
        let retained = try XCTUnwrap(DownloadManager.localAudioURL(jobId: jobID, chapterIndex: 0))
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
    }
}
#endif
