#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

final class TocAudioAvailabilityPresentationTests: XCTestCase {
    @MainActor
    func testReadyChapterAccessoryPreservesSourceIndexWhileDownloadedAudioRequiresMenuIntent() throws {
        var downloads: [Int] = []
        var removals: [Int] = []
        func row(downloaded: Bool) -> TocAudioAvailabilityPresentation.Row {
            .init(title: "Original chapter", zeroBasedIndex: 7, charCount: 20,
                  isCurrent: false, audioReady: true, downloaded: downloaded,
                  artifactState: .available, schedulerState: nil)
        }
        let ready = try XCTUnwrap(TocAudioAvailabilityPresentation.makeAccessoryView(
            for: row(downloaded: false), onDownload: { downloads.append($0) },
            onRemoveDownload: { index, _ in removals.append(index) }
        ) as? UIButton)
        ready.sendActions(for: .touchUpInside)
        XCTAssertEqual(downloads, [7])
        XCTAssertEqual(ready.accessibilityIdentifier, "reader.toc.download.7")
        let downloaded = try XCTUnwrap(TocAudioAvailabilityPresentation.makeAccessoryView(
            for: row(downloaded: true), onDownload: { downloads.append($0) },
            onRemoveDownload: { index, _ in removals.append(index) }
        ) as? UIButton)
        XCTAssertTrue(downloaded.showsMenuAsPrimaryAction)
        XCTAssertNotNil(downloaded.menu)
        downloaded.sendActions(for: .touchUpInside)
        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(downloads, [7])
    }
}
#endif
