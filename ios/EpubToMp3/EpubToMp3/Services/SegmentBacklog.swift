import Foundation

/// Backlog of TTS segments waiting to be appended to the AVQueuePlayer.
///
/// Extracted from `AudioPlayer` so the queue-eviction policy + the
/// empty-streak detector can be unit-tested without an AVPlayer mock.
/// AudioPlayer keeps a single `var backlog = SegmentBacklog()` and
/// mutates it through these methods; the AVFoundation-aware code
/// (creating `AVPlayerItem`s, inserting into the queue) stays in
/// AudioPlayer where it belongs.
struct SegmentBacklog {
    struct Entry: Equatable {
        let url: URL
        let chapterIndex: Int
        let segmentIndex: Int
        let sentenceId: String?
    }

    /// Per the audit: 50 entries × 100-500 KB temp files = bounded
    /// disk pressure if the user has the reader open during
    /// conversion but never taps Play. The AVQueuePlayer has its own
    /// 5-item look-ahead (`AudioPlayer.maxQueueAhead`); this cap
    /// applies to the *deferred* backlog beyond that.
    static let capacity: Int = 50

    /// Edge-TTS sometimes emits a zero-byte preamble during warmup.
    /// Surfacing it as an error on the first occurrence would spam
    /// the toast; we only escalate after N consecutive empties.
    static let emptyStreakErrorThreshold: Int = 5

    private(set) var entries: [Entry] = []
    private(set) var emptyStreak: Int = 0

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Push a new segment. Returns the URL of any entry that was
    /// evicted to make room — caller should delete the file from
    /// disk so descriptors don't leak.
    mutating func append(
        url: URL,
        chapterIndex: Int,
        segmentIndex: Int,
        sentenceId: String? = nil
    ) -> URL? {
        var evicted: URL?
        if entries.count >= Self.capacity {
            evicted = entries.removeFirst().url
        }
        entries.append(
            Entry(
                url: url,
                chapterIndex: chapterIndex,
                segmentIndex: segmentIndex,
                sentenceId: sentenceId
            )
        )
        return evicted
    }

    /// Pop the next entry off the front. Returns `nil` when empty.
    mutating func drainNext() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    /// Record an empty-data segment arrival. Returns `true` when the
    /// streak crosses `emptyStreakErrorThreshold` (caller surfaces
    /// the error toast); `false` otherwise.
    mutating func recordEmpty() -> Bool {
        emptyStreak += 1
        return emptyStreak >= Self.emptyStreakErrorThreshold
    }

    /// Reset the empty-streak counter — call on every successful
    /// (non-empty) segment so a real failure has to rebuild the
    /// streak from scratch.
    mutating func resetEmptyStreak() {
        emptyStreak = 0
    }

    /// Wipe the backlog (queue rebuild). Returns the URLs the caller
    /// should delete from disk.
    mutating func clear() -> [URL] {
        let urls = entries.map(\.url)
        entries.removeAll()
        emptyStreak = 0
        return urls
    }
}
