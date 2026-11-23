import Foundation

/// Owns resume persistence policy and its write throttle. Queue lifecycle stays
/// with AudioPlayer; persisted playing/loading state never activates transport.
/// Offline retention of heard chapters lives in `PlaybackArtifactRetention`.
@MainActor
final class PlaybackResumeStore {
    private let location: ReaderLocation
    private let resumeStore: ResumeStore
    private var lastResumePersist: Date = .distantPast

    init(store: ResumeStore, location: ReaderLocation) {
        self.location = location
        resumeStore = store
    }

    func marker(jobId: String, chapterIndex: Int) -> ResumeMarker? { resumeStore.marker(jobId: jobId, chapterIndex: chapterIndex) }
    func saveBeforeTeardown(_ marker: ResumeMarker) {
        resumeStore.save(jobId: marker.jobId, chapterIndex: marker.chapterIndex, position: marker.positionSeconds)
    }


    func persist(snapshot: JobSnapshot?, chapterIndex: Int, sourceChapterIndex: Int?,
                 positionSeconds: TimeInterval, isPlaying: Bool, force: Bool) {
        // Queue offsets remain internal resume-marker keys. The app shell and
        // reader restore only source chapter identities, never an unresolved 0.
        guard let snapshot, let sourceChapterIndex, sourceChapterIndex >= 0 else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastResumePersist) < 5 { return }
        lastResumePersist = now
        let resumePosition = Self.positionForPersistedState(
            positionSeconds: positionSeconds,
            wasPlaying: isPlaying
        )
        resumeStore.save(
            jobId: snapshot.jobId,
            chapterIndex: chapterIndex,
            position: resumePosition,
            wasPlaying: isPlaying,
            now: now
        )
        location.playingChapter = sourceChapterIndex
    }

    static func sourceChapterIndex(snapshot: JobSnapshot?, playbackChapters: [JobSnapshot.Chapter],
                                   queueOffset: Int, segmentMode: Bool, segmentChapterIndex: Int) -> Int? {
        guard snapshot != nil else { return nil }
        if segmentMode { return segmentChapterIndex >= 0 ? segmentChapterIndex : nil }
        return PlaybackChapterQueue.chapterValue(snapshot: snapshot, playbackChapters: playbackChapters,
            currentChapterIndex: queueOffset, isSegmentMode: false)?.index
    }

    nonisolated static func positionForPersistedState(
        positionSeconds: TimeInterval,
        wasPlaying: Bool
    ) -> TimeInterval {
        let position = max(0, positionSeconds)
        return wasPlaying ? max(0, position - 15) : position
    }

    nonisolated static func markerBeforeTeardown(
        jobId: String?,
        chapterIndex: Int,
        positionSeconds: TimeInterval
    ) -> ResumeMarker? {
        guard let jobId,
              positionSeconds.isFinite,
              positionSeconds > 1.0 else { return nil }
        return ResumeMarker(
            jobId: jobId,
            chapterIndex: chapterIndex,
            positionSeconds: positionSeconds,
            updatedAt: .distantPast
        )
    }

    /// UserDefaults key holding the `BookEntity.id` of the book that was
    /// most recently bound to playback via `PlaybackBindingStore`.
    /// Written when the user begins playback so the shell can rehydrate
    /// after a cold launch. Centralised here so the rest of the app
    /// shares a single source of truth.
    /// `nonisolated` — a plain string constant carries no actor state,
    /// so it must be referenceable from any context (tests, nonisolated
    /// call sites) without a Swift-6 main-actor-isolation warning.
    nonisolated static let currentBookIDDefaultsKey = ReaderLocation.Key.playingBook

    /// Companion key — zero-based chapter index of the resumed book.
    nonisolated static let currentChapterIndexDefaultsKey = ReaderLocation.Key.playingChapter
}
