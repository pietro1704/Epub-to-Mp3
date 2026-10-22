#if DEBUG
import AVFoundation
import Foundation

/// Fixture and inspection surface for real playback seams. It holds authority
/// weakly and never creates a production command or a second session.
@MainActor
final class PlaybackTestAccess {
    // Direct setters for state that is `@Published private(set)` or
    // private — used by `AudioPlayerDivergenceTests` to construct the
    // exact state matrix the decision/seek helpers must handle.
    // Strictly compiled-in: not referenced from product code.
    private weak var authority: AudioPlayer?
    private let services: PlaybackServices
    init(authority: AudioPlayer, services: PlaybackServices) {
        self.authority = authority
        self.services = services
    }
    func setIsPlaying(_ value: Bool) { authority?.playbackPlayingChanged(value) }
    func currentPlayerItem() -> AVPlayerItem? { services.queue.player?.currentItem }
    func setSnapshot(_ snap: JobSnapshot) { authority?.playbackSnapshotChanged(snap) }
    func setCurrentChapterIndex(_ idx: Int) { services.queue.selectChapter(idx) }
    func setDurationSeconds(_ value: Double) { services.clock.update(durationSeconds: value) }
    func playbackChapterCount() -> Int { services.chapters.chapters.count }
    func sentenceTimingMap(forChapterIndex idx: Int) -> [String: Int]? {
        services.reader.timingMap(for: idx)
    }
    func activeSegmentIdentity() -> SegmentBacklog.Identity? {
        services.segments.activeIdentity
    }
    func deferredSegmentCount() -> Int { services.segments.deferredCount }
    func retainedSegmentCount() -> Int { services.segments.files.count }
    func segmentURL(chapterIndex: Int, segmentIndex: Int) -> URL? {
        services.segments.files[.init(chapterIndex: chapterIndex, segmentIndex: segmentIndex)]
    }
    func activateSegment(chapterIndex: Int, segmentIndex: Int) {
        _ = services.queue.activateSegment(
            .init(chapterIndex: chapterIndex, segmentIndex: segmentIndex), segments: services.segments
        )
    }
    func segmentChapterIndex() -> Int { services.segments.chapterIndex }
    func activeSegmentSentenceCount() -> Int {
        services.segments.files.keys.filter { $0.chapterIndex == services.segments.chapterIndex }.count
    }
    func activateSegmentChapter(_ chapterIndex: Int) {
        guard let identity = services.segments.files.keys
            .filter({ $0.chapterIndex == chapterIndex })
            .min() else { return }
        _ = services.queue.activateSegment(identity, segments: services.segments)
    }
    func bufferedSegmentChapterCount() -> Int {
        services.segments.files.keys.filter { $0.chapterIndex == services.segments.chapterIndex }.count
    }
    func completeSegmentTiming(chapterIndex: Int) {
        guard chapterIndex == services.segments.chapterIndex else { return }
        services.segments.setBase(max(services.segments.cumulativeBase, services.clock.positionSeconds))
    }
    func registerOwnedSegmentItem(_ item: AVPlayerItem) {
        services.queue.register(ObjectIdentifier(item))
    }
    func isOwnedSegmentItem(_ item: AVPlayerItem) -> Bool {
        services.queue.owns(ObjectIdentifier(item))
    }
    func removeOwnedSegmentItem(_ item: AVPlayerItem) {
        services.queue.removeOwnership(ObjectIdentifier(item))
    }
    func backlogCount() -> Int { services.segments.deferredCount }
    func segmentCapacityWaiterCount() -> Int { services.segments.capacityWaiterCount }
    func segmentTempDirectory() -> URL? { services.persistence.directory }
    func teardownPlayer() { services.lifecycle.teardown() }
    func finishCurrentSegment() -> Bool {
        guard let queue = services.queue.player, let item = queue.currentItem else { return false }
        queue.advanceToNextItem()
        services.observation.handleFinishedItem(item)
        return true
    }
    /// Simulate the post-`enqueueSegment` state in the embedded-runtime
    /// path: a live AVQueuePlayer carrying a synthesised MP3 with no
    /// snapshot-side `downloadUrl`. Used by the regression test for
    /// `playTapDecision` short-circuiting to `.resume` when there is
    /// nothing for the divergence dialog to resolve.
    func simulateSegmentMode() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub2mp3-test-\(UUID().uuidString).mp3")
        // 1 KB of zero bytes is enough to instantiate AVPlayerItem;
        // we never start playback in tests so an invalid MP3 payload
        // is fine.
        try? Data(count: 1024).write(to: tmp)
        let item = AVPlayerItem(url: tmp)
        let queue = AVQueuePlayer(items: [item])
        queue.actionAtItemEnd = .advance
        queue.rate = 0
        services.queue.mount(queue)
        authority?.playbackSegmentModeChanged(true)
    }
}
#endif
