import XCTest
@testable import EpubToMp3

final class DownloadManagerStorageTests: XCTestCase {
    func testMacOSAudiobookCacheIsInsideApplicationSupport() {
        #if os(macOS)
        let root = DownloadManager.audiobooksRoot().standardizedFileURL.path
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
            .path
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
            .path

        XCTAssertTrue(
            root.hasPrefix(applicationSupport + "/"),
            "macOS app-owned audiobook data must stay inside Application Support"
        )
        XCTAssertFalse(
            root.hasPrefix(documents + "/"),
            "macOS app-owned audiobook data must not trigger access to the user's Documents folder"
        )
        #else
        XCTAssertTrue(
            DownloadManager.audiobooksRoot().path.contains("Audiobooks"),
            "iOS audiobook storage must retain its app-local Documents layout"
        )
        #endif
    }
}
