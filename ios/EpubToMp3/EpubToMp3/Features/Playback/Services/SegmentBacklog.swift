import Foundation

/// Backlog of TTS segments waiting to be appended to the AVQueuePlayer.
///
/// Segments are already file-backed when they reach this type, so the
/// deferred queue stores only their small identity/URL metadata. It must
/// never evict an entry: deleting a deferred file means deleting a portion
/// of the book the user asked to hear. Entries remain available until
/// `AudioPlayer` successfully inserts them into AVQueuePlayer or tears the
/// entire playback session down.
struct SegmentBacklog {
    /// Stable producer identity. Python emits zero-based indexes within a
    /// chapter, and the embedded coordinator emits chapters in EPUB order.
    /// Sorting by this identity makes deferred insertion deterministic even
    /// when MainActor deliveries arrive in a different turn.
    struct Identity: Hashable, Comparable {
        let chapterIndex: Int
        let segmentIndex: Int

        static func < (lhs: Identity, rhs: Identity) -> Bool {
            if lhs.chapterIndex != rhs.chapterIndex {
                return lhs.chapterIndex < rhs.chapterIndex
            }
            return lhs.segmentIndex < rhs.segmentIndex
        }
    }

    struct Entry: Equatable {
        let url: URL
        let identity: Identity
        let sentenceId: String?

        var chapterIndex: Int { identity.chapterIndex }
        var segmentIndex: Int { identity.segmentIndex }
    }

    /// The maximum number of file-backed segments waiting outside
    /// `AVQueuePlayer`. `AudioPlayer` applies backpressure before this limit
    /// is reached; it never evicts a segment merely because playback is
    /// slower than conversion.
    static let maximumDeferredSegmentCount: Int = 50

    /// Compatibility name retained for existing diagnostics and tests.
    static let advisoryHighWaterMark = maximumDeferredSegmentCount

    /// Edge-TTS sometimes emits a zero-byte preamble during warmup.
    /// Surfacing it as an error on the first occurrence would spam
    /// the toast; we only escalate after N consecutive empties.
    static let emptyStreakErrorThreshold: Int = 5

    private(set) var entries: [Entry] = []
    private(set) var emptyStreak: Int = 0
    private(set) var highWaterMark: Int = 0

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var exceedsAdvisoryHighWaterMark: Bool { count >= Self.advisoryHighWaterMark }

    /// Inspect the next segment without removing it. The AV queue must
    /// accept the item before callers drain it, otherwise a transient
    /// `canInsert` failure silently loses spoken audio.
    func peekNext() -> Entry? { entries.first }

    /// Push a new segment, preserving deterministic stream order. Returns
    /// `false` for a duplicate identity; the caller can then keep the first
    /// file intact instead of replacing an AVFoundation asset in place.
    ///
    /// There is deliberately no capacity-based eviction. The session owner
    /// removes every retained file only after it was inserted or on teardown.
    @discardableResult
    mutating func append(
        url: URL,
        chapterIndex: Int,
        segmentIndex: Int,
        sentenceId: String? = nil
    ) -> Bool {
        let identity = Identity(chapterIndex: chapterIndex, segmentIndex: segmentIndex)
        guard !entries.contains(where: { $0.identity == identity }) else { return false }

        let entry = Entry(url: url, identity: identity, sentenceId: sentenceId)
        if let insertionIndex = entries.firstIndex(where: { identity < $0.identity }) {
            entries.insert(entry, at: insertionIndex)
        } else {
            entries.append(entry)
        }
        highWaterMark = max(highWaterMark, entries.count)
        return true
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
        highWaterMark = 0
        return urls
    }
}
