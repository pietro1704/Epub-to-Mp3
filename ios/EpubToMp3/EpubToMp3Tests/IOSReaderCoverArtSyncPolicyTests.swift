#if os(iOS)
import XCTest
@testable import EpubToMp3

final class IOSReaderCoverArtSyncPolicyTests: XCTestCase {
    func testNowPlayingCoverRequiresAnAudioSession() {
        XCTAssertFalse(IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: false, isConverting: false, hasLoadedAudioQueue: false
        ))
        XCTAssertTrue(IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: true, isConverting: false, hasLoadedAudioQueue: false
        ))
        XCTAssertTrue(IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: false, isConverting: true, hasLoadedAudioQueue: false
        ))
        XCTAssertTrue(IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: false, isConverting: false, hasLoadedAudioQueue: true
        ))
    }
}
#endif
