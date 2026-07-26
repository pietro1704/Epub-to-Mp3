import XCTest
@testable import EpubToMp3

final class DownloadManagerResumeTests: XCTestCase {
    func testExistingManifestEntryIsReusableOnlyWhenTheFileIsPresent() {
        let entry = AudiobookManifest.ChapterEntry(
            index: 3,
            title: "Chapter 3",
            mp3FileName: "chapter-3.mp3",
            mp3Bytes: 128,
            downloadedAt: Date()
        )

        XCTAssertNotNil(DownloadManager.reusableDownloadedEntry(
            chapterIndex: 3, manifestEntry: entry, fileExists: true
        ))
        XCTAssertNil(DownloadManager.reusableDownloadedEntry(
            chapterIndex: 3, manifestEntry: entry, fileExists: false
        ))
        XCTAssertNil(DownloadManager.reusableDownloadedEntry(
            chapterIndex: 2, manifestEntry: entry, fileExists: true
        ))
    }
}
