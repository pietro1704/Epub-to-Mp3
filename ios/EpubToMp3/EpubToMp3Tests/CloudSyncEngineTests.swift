import XCTest
import CloudKit
@testable import EpubToMp3

final class CloudSyncEngineTests: XCTestCase {

    func testRecordTypeConstant() {
        XCTAssertEqual(CloudSyncEngine.recordType, "Book")
    }

    func testContainerIdentifier() {
        XCTAssertEqual(CloudSyncEngine.containerIdentifier, "iCloud.com.epubtomp3.library")
    }

    func testInitialSyncStatusIsIdle() {
        let suite = "test.cloud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let library = LibraryStore(defaults: defaults, defaultsKey: "cloud.test")
        let engine = CloudSyncEngine(library: library, defaults: defaults)
        XCTAssertEqual(engine.syncStatus, .idle)
        XCTAssertNil(engine.lastSyncDate)
    }
}
