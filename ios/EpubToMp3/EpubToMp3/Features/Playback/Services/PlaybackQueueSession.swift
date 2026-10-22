import Foundation
import AVFoundation
import Combine

/// AVAudioPlayer is single-file; AVPlayer needs manual replaceCurrentItem/KVO
/// work for gapless transitions. AVQueuePlayer owns that advance and buffering.
/// Rebuilding a paused queue must never claim audio focus from another app.
/// Owns AVQueuePlayer observation and item membership. It reports facts to the
/// coordinator; it never chooses chapters, autoplay, generation or resume state.
@MainActor
final class PlaybackQueueSession: ObservableObject {
    @Published private(set) var currentChapterIndex = 0
    /// Active sentence ID in sentence-per-segment mode. Updated when the
    /// AVQueuePlayer advances to the next item. `nil` in snapshot mode.
    @Published private(set) var activeSentenceId: String?
    private let clock: PlaybackClock
    init(clock: PlaybackClock? = nil) { self.clock = clock ?? PlaybackClock() }
    func selectChapter(_ chapter: Int) { currentChapterIndex = chapter }
    func selectSentence(_ sentence: String?) { activeSentenceId = sentence }
    nonisolated static let maximumAhead = 5
    // `nonisolated(unsafe)` so `deinit` (which is non-isolated on a
    // `@MainActor` class under Swift 6) can read these to detach
    // observers before the wrapper is freed. The tokens themselves
    // are opaque `Any` / `NSObjectProtocol` references safe to release
    // off-main; the AVQueuePlayer is also fine to teardown from any
    // thread (AVFoundation handles its own internal serialisation).
    /// KVO token for `AVQueuePlayer.currentItem`. Fires whenever the queue
    /// advances to the next item (including auto-advance at natural end) so
    /// `MPNowPlayingInfoCenter` is always refreshed with the correct chapter
    /// title and duration — even when the OS advances the item before our
    /// `AVPlayerItemDidPlayToEndTime` handler runs.
    /// True only after an AV queue exists. A snapshot may arrive before its
    /// first audio segment, so snapshot presence alone is not enough to make
    /// a Play tap audible.
    nonisolated(unsafe) private(set) var player: AVQueuePlayer?
    nonisolated(unsafe) private var timeObserverToken: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var currentItemObserver: NSKeyValueObservation?
    private var itemObservationCancellables = Set<AnyCancellable>()
    /// AVQueuePlayer removes a finished item before it posts the end
    /// notification. Keep the identities registered at insertion time so the
    /// end handler can filter unrelated players without missing our own
    /// buffer-drain event.
    private var ownedPlayerItemIDs: Set<ObjectIdentifier> = []

    deinit {
        // addPeriodicTimeObserver must be detached before the player is freed.
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        currentItemObserver?.invalidate()
        // Failed/test items must not keep AVFoundation workers alive after ARC.
        let queuedPlayer = player
        Task { @MainActor [queuedPlayer] in
            queuedPlayer?.pause()
            queuedPlayer?.removeAllItems()
        }
    }
    func mount(_ player: AVQueuePlayer) { self.player = player }
    func replaceOwnership(_ identities: Set<ObjectIdentifier>) { ownedPlayerItemIDs = identities }
    func register(_ identity: ObjectIdentifier) { ownedPlayerItemIDs.insert(identity) }
    @discardableResult
    func removeOwnership(_ identity: ObjectIdentifier) -> Bool { ownedPlayerItemIDs.remove(identity) != nil }
    func owns(_ identity: ObjectIdentifier) -> Bool { ownedPlayerItemIDs.contains(identity) }
    func clearOwnership() { ownedPlayerItemIDs.removeAll() }

    func teardown() {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        itemObservationCancellables.removeAll()
        player?.pause()
        player = nil
        ownedPlayerItemIDs.removeAll()
    }

    func observe(time: @escaping @MainActor @Sendable (CMTime, AVQueuePlayer) -> Void,
                 finished: @escaping @MainActor @Sendable (AVPlayerItem) -> Void,
                 itemChanged: @escaping @MainActor @Sendable () -> Void,
                 duration: @escaping @MainActor @Sendable (TimeInterval) -> Void) {
        guard let player else { return }
        if let item = player.currentItem { bindDuration(to: item, in: player, changed: duration) }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                time(value, player)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self, weak player] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, let player, self.player === player,
                      self.owns(ObjectIdentifier(item)) else { return }
                finished(item)
            }
        }
        // KVO catches auto-advance before the end notification. Duration binding
        // is replaced before the coordinator reconciles and publishes its title.
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                if let item = player.currentItem { self.bindDuration(to: item, in: player, changed: duration) }
                else { self.itemObservationCancellables.removeAll() }
                itemChanged()
            }
        }
    }

    private func bindDuration(to item: AVPlayerItem, in player: AVQueuePlayer, changed: @escaping @MainActor @Sendable (TimeInterval) -> Void) {
        itemObservationCancellables.removeAll()
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item, weak player] status in
                MainActor.assumeIsolated {
                    guard let self, let item, let player, self.player === player,
                          player.currentItem === item else { return }
                    if let duration = PlaybackSegmentSession.validatedDurationSeconds(item.duration.seconds, isReadyToPlay: status == .readyToPlay) {
                        changed(duration)
                    }
                }
            }.store(in: &itemObservationCancellables)
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item, weak player] duration in
                MainActor.assumeIsolated {
                    guard let self, let item, let player, self.player === player,
                          player.currentItem === item else { return }
                    if let value = PlaybackSegmentSession.validatedDurationSeconds(duration.seconds, isReadyToPlay: item.status == .readyToPlay) {
                        changed(value)
                    }
                }
            }.store(in: &itemObservationCancellables)
    }
    /// Only a confirmed audible item may change the visible chapter/sentence.
    /// Buffered producer activity never calls this transition.
    @discardableResult
    func activateSegment(_ identity: SegmentBacklog.Identity, segments: PlaybackSegmentSession) -> Bool {
        let changed = segments.activate(identity)
        if changed {
            clock.update(durationSeconds: max(0, segments.estimatedDurations[identity.chapterIndex] ?? 0))
            activeSentenceId = nil
        }
        currentChapterIndex = identity.chapterIndex
        activeSentenceId = segments.sentenceIDs[identity]
        return changed
    }

    @discardableResult
    func activateCurrentSegment(segments: PlaybackSegmentSession) -> Bool {
        guard let asset = player?.currentItem?.asset as? AVURLAsset,
              let identity = PlaybackSegmentSession.segmentIdentityForSegmentItem(asset.url) else { return false }
        return activateSegment(identity, segments: segments)
    }

    /// KVO can precede end notification. Resolve the actual queue item rather
    /// than guessing its index from the sorted incoming snapshot.
    @discardableResult
    func reconcileChapter(segmentMode: Bool, segments: PlaybackSegmentSession,
                          chapterURLs: () -> [URL?]?) -> Bool {
        guard let asset = player?.currentItem?.asset as? AVURLAsset else { return false }
        if segmentMode {
            guard let identity = PlaybackSegmentSession.segmentIdentityForSegmentItem(asset.url) else { return false }
            let changed = activateSegment(identity, segments: segments)
            if changed { clock.update(positionSeconds: 0) }
            return changed
        }
        guard let urls = chapterURLs(), let index = PlaybackChapterQueue.resolveChapterIndex(
            currentIndex: currentChapterIndex, chapterURLs: urls, currentItemURL: asset.url),
              index != currentChapterIndex else { return false }
        currentChapterIndex = index
        clock.update(positionSeconds: 0)
        return true
    }

    func drainSegments(_ segments: PlaybackSegmentSession) {
        guard let player else { return }
        for item in segments.drain(into: player, maximumAhead: Self.maximumAhead) {
            register(ObjectIdentifier(item))
        }
    }

    enum Completion { case chapterAdvanced, ended }
    func finish(_ item: AVPlayerItem, segmentMode: Bool, segments: PlaybackSegmentSession,
                snapshot: () -> JobSnapshot?, chapterCount: () -> Int,
                chapterURLs: () -> [URL?]?) -> Completion? {
        // Items are removed before notification; retained identity, not items(),
        // establishes ownership. Notifications for another player do nothing.
        guard removeOwnership(ObjectIdentifier(item)) else { return nil }
        let duration = item.duration.seconds
        let identity = (item.asset as? AVURLAsset).flatMap {
            PlaybackSegmentSession.segmentIdentityForSegmentItem($0.url)
        }
        if segmentMode, identity?.chapterIndex == segments.chapterIndex, duration.isFinite {
            // A delayed notification cannot advance a chapter already promoted
            // by KVO. Only the still-audible chapter contributes cumulative time.
            segments.advanceBase(duration)
        }
        drainSegments(segments)
        _ = activateCurrentSegment(segments: segments)
        guard let snapshot = snapshot() else { return nil }
        let total = segmentMode ? (snapshot.chapterProgress?.count ?? 0) : chapterCount()
        guard !segmentMode else { return nil }
        guard currentChapterIndex + 1 < total else { return .ended }
        let previous = currentChapterIndex
        _ = reconcileChapter(segmentMode: false, segments: segments, chapterURLs: chapterURLs)
        // Reconciliation returns false both for an unknown URL and a cursor
        // already promoted by KVO; preserve the established completion order.
        if currentChapterIndex == previous {
            currentChapterIndex += 1
            clock.update(positionSeconds: 0)
        }
        return .chapterAdvanced
    }

    func updateClock(rawTime: TimeInterval, seeking: Bool, segmentMode: Bool,
                     segments: PlaybackSegmentSession, snapshot: () -> JobSnapshot?) {
        guard let player else { return }
        if !seeking { clock.update(positionSeconds: segmentMode ? segments.cumulativeBase + rawTime : rawTime) }
        if let item = player.currentItem,
           let duration = PlaybackSegmentSession.validatedDurationSeconds(item.duration.seconds, isReadyToPlay: true) {
            clock.update(durationSeconds: segmentMode ? segments.observeDuration(queue: player, snapshot: snapshot()) : duration)
        }
    }

    func skip(by delta: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard let player else { return nil }
        let raw = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        let cap = duration.isFinite && duration > 0 ? duration : .infinity
        let target = max(0, min(cap, raw + delta))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        return target
    }

    func rewind(chapter: Int, segmentMode: Bool, isPlaying: Bool, rate: PlaybackRate) -> Bool {
        guard let queue = player else { return false }
        if segmentMode {
            let items = queue.items()
            guard let firstIndex = items.firstIndex(where: { item in
                guard let asset = item.asset as? AVURLAsset else { return false }
                return PlaybackSegmentSession.chapterIndexForSegmentItem(asset.url) == chapter
            }) else { return false }
            let remaining = Array(items[firstIndex...])
            queue.removeAllItems()
            var previous: AVPlayerItem?
            for item in remaining {
                queue.insert(item, after: previous)
                previous = item
            }
            queue.seek(to: .zero)
            queue.rate = isPlaying ? rate.rawValue : 0
        } else { queue.seek(to: .zero) }
        return true
    }

}
