import Foundation

enum IOSReaderCoverArtSyncPolicy {
    static func shouldPublishNowPlayingCover(
        hasSnapshot: Bool,
        isConverting: Bool,
        hasLoadedAudioQueue: Bool
    ) -> Bool {
        hasSnapshot || isConverting || hasLoadedAudioQueue
    }
}
