#if os(iOS)
import UIKit

enum IOSReaderCoverArtSyncPolicy {
    static func shouldPublishNowPlayingCover(
        hasSnapshot: Bool,
        isConverting: Bool,
        hasLoadedAudioQueue: Bool
    ) -> Bool {
        hasSnapshot || isConverting || hasLoadedAudioQueue
    }
}

#endif
