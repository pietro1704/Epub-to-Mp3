import AVFoundation
import Foundation
@testable import EpubToMp3

/// Multi-step fixtures over the real playback services. Single reads and
/// writes go straight through `player.services` at the call site.
@MainActor
extension AudioPlayer {
    /// Retained segment files of the chapter the segment session is on.
    func activeChapterSegmentCount() -> Int {
        services.segments.files.keys.filter { $0.chapterIndex == services.segments.chapterIndex }.count
    }

    /// Activates the first retained segment of `chapterIndex`, if any.
    func activateFirstSegment(ofChapter chapterIndex: Int) {
        guard let identity = services.segments.files.keys
            .filter({ $0.chapterIndex == chapterIndex })
            .min() else { return }
        _ = services.queue.activateSegment(identity, segments: services.segments)
    }

    func activateSegment(chapterIndex: Int, segmentIndex: Int) {
        _ = services.queue.activateSegment(
            .init(chapterIndex: chapterIndex, segmentIndex: segmentIndex), segments: services.segments
        )
    }

    /// Moves the cumulative segment base to the current clock position, as a
    /// finished chapter timing does.
    func completeSegmentTiming(chapterIndex: Int) {
        guard chapterIndex == services.segments.chapterIndex else { return }
        services.segments.setBase(max(services.segments.cumulativeBase, services.clock.positionSeconds))
    }

    /// Advances the queue past its current item and delivers the finish event.
    func finishCurrentSegment() -> Bool {
        guard let queue = services.queue.player, let item = queue.currentItem else { return false }
        queue.advanceToNextItem()
        services.observation.handleFinishedItem(item)
        return true
    }

    /// Mounts a live, paused AVQueuePlayer carrying a synthesised MP3 with no
    /// snapshot-side `downloadUrl`, the state after an embedded-runtime
    /// `enqueueSegment`.
    func simulateSegmentMode() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub2mp3-test-\(UUID().uuidString).mp3")
        // 1 KB of zero bytes instantiates an AVPlayerItem; tests never start
        // playback, so the invalid MP3 payload is fine.
        try? Data(count: 1024).write(to: tmp)
        let item = AVPlayerItem(url: tmp)
        let queue = AVQueuePlayer(items: [item])
        queue.actionAtItemEnd = .advance
        queue.rate = 0
        services.queue.mount(queue)
        playbackSegmentModeChanged(true)
    }
}
