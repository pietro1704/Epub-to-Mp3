import Foundation
import AVFoundation

/// Owns resume persistence policy and its write throttle. Queue lifecycle stays
/// with AudioPlayer; persisted playing/loading state never activates transport.
@MainActor
final class PlaybackResumeStore {
    private var lastPlaybackRetentionRequest: (bookID: String, chapterIndex: Int)?
    private struct RetentionTarget: Hashable { let bookID: String; let chapterIndex: Int }
    private var retentionTasks: [RetentionTarget: Task<Void, Never>] = [:]
    private var retentionGeneration = UUID()
    private let retainArtifact: (String, Int) async throws -> Void
    func resetRetention() {
        lastPlaybackRetentionRequest = nil
        retentionGeneration = UUID()
    }
    private let resumeStore: ResumeStore
    private var lastResumePersist: Date = .distantPast

    init(store: ResumeStore, artifactStore: LocalAudioArtifactStore? = nil,
         retainArtifact: ((String, Int) async throws -> Void)? = nil) {
        resumeStore = store
        let artifacts = artifactStore ?? .shared
        self.retainArtifact = retainArtifact ?? { book, chapter in
            try await artifacts.requestPlaybackRetention(bookID: book, chapterIndex: chapter)
        }
    }

    func marker(jobId: String, chapterIndex: Int) -> ResumeMarker? { resumeStore.marker(jobId: jobId, chapterIndex: chapterIndex) }
    func saveBeforeTeardown(_ marker: ResumeMarker) {
        resumeStore.save(jobId: marker.jobId, chapterIndex: marker.chapterIndex, position: marker.positionSeconds)
    }


    func persist(snapshot: JobSnapshot?, chapterIndex: Int, positionSeconds: TimeInterval, isPlaying: Bool, force: Bool) {
        guard let snapshot else { return }
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
        UserDefaults.standard.set(
            chapterIndex,
            forKey: Self.currentChapterIndexDefaultsKey
        )
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
    nonisolated static let currentBookIDDefaultsKey = "currentlyPlayingBookID"

    /// Companion key — zero-based chapter index of the resumed book.
    nonisolated static let currentChapterIndexDefaultsKey = "currentlyPlayingChapterIndex"

    func recordAudibleChapter(player: AVQueuePlayer?, snapshot: JobSnapshot?, isSegmentMode: Bool,
                              segments: PlaybackSegmentSession, playbackChapters: [JobSnapshot.Chapter],
                              currentChapterIndex: Int, resolveURL: (String?, String, Int) -> URL?) {
        guard let player, let snapshot, snapshot.jobId.hasPrefix("embedded-"),
              let bookID = Self.artifactBookID(jobID: snapshot.jobId) else { return }
        let renderedSeconds = player.currentTime().seconds
        guard renderedSeconds.isFinite,
              PlaybackJourneyRecorder.hasAudibleOutput(timeControlStatus: player.timeControlStatus,
                                    renderedSeconds: renderedSeconds) else { return }
        let chapterIndex: Int
        if isSegmentMode {
            guard let asset = player.currentItem?.asset as? AVURLAsset,
                  let identity = PlaybackSegmentSession.segmentIdentityForSegmentItem(asset.url),
                  segments.files[identity] == asset.url else { return }
            chapterIndex = identity.chapterIndex
        } else {
            // SSE snapshots are sorted by EPUB identity, but late arrivals
            // append to the live queue. Resolve the actual item against that
            // queue so publishing an earlier chapter never retains it unheard.
            let chapters = playbackChapters.isEmpty ? snapshot.playableChapters : playbackChapters
            guard let asset = player.currentItem?.asset as? AVURLAsset else { return }
            if chapters.indices.contains(currentChapterIndex),
               resolveURL(chapters[currentChapterIndex].downloadUrl,
                           snapshot.jobId,
                           chapters[currentChapterIndex].index) == asset.url {
                chapterIndex = chapters[currentChapterIndex].index
            } else {
                guard let offset = PlaybackChapterQueue.resolveChapterIndex(
                    currentIndex: currentChapterIndex,
                    chapterURLs: chapters.map {
                        resolveURL($0.downloadUrl,
                                    snapshot.jobId, $0.index)
                    },
                    currentItemURL: asset.url) else { return }
                chapterIndex = chapters[offset].index
            }
        }
        requestArtifactRetention(bookID: bookID, chapterIndex: chapterIndex)
    }

    /// A confirmed audible chapter is durable intent even if transport stops
    /// while the artifact actor is saving it. Failed writes remain retryable.
    @discardableResult
    func requestArtifactRetention(bookID: String, chapterIndex: Int) -> Task<Void, Never>? {
        let target = RetentionTarget(bookID: bookID, chapterIndex: chapterIndex)
        if let pending = retentionTasks[target] { return pending }
        guard lastPlaybackRetentionRequest?.bookID != bookID
                || lastPlaybackRetentionRequest?.chapterIndex != chapterIndex else { return nil }
        let generation = retentionGeneration
        let retain = retainArtifact
        let task = Task { @MainActor [weak self] in
            do {
                try await retain(bookID, chapterIndex)
                if let self, self.retentionGeneration == generation {
                    self.lastPlaybackRetentionRequest = (bookID, chapterIndex)
                }
            } catch {
                AppErrorReporter.message(error, context: "Playback retention")
            }
            self?.retentionTasks.removeValue(forKey: target)
        }
        retentionTasks[target] = task
        return task
    }

    nonisolated private static func artifactBookID(jobID: String) -> String? {
        let prefix = "embedded-"
        let bookID = jobID.hasPrefix(prefix) ? String(jobID.dropFirst(prefix.count)) : jobID
        return bookID.isEmpty ? nil : bookID
    }

    /// Resolves a player queue offset back to the canonical embedded-book
    /// artifact. A partial snapshot contains only available chapters, so the
    /// queue offset is not necessarily the EPUB chapter index.
    nonisolated static func playbackRetentionTarget(
        snapshot: JobSnapshot,
        playableChapterOffset: Int
    ) -> (bookID: String, chapterIndex: Int)? {
        guard snapshot.playableChapters.indices.contains(playableChapterOffset) else {
            return nil
        }
        guard let bookID = artifactBookID(jobID: snapshot.jobId) else { return nil }
        return (bookID, snapshot.playableChapters[playableChapterOffset].index)
    }

}
