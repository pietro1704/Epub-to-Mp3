import Foundation
import AVFoundation

/// Requests offline retention of every chapter that playback confirmed
/// audible, once per book and chapter, retrying failed writes. Retention
/// intent survives a transport stop; `resetRetention` starts a new session.
@MainActor
final class PlaybackArtifactRetention {
    private var lastPlaybackRetentionRequest: (bookID: String, chapterIndex: Int)?
    private struct RetentionTarget: Hashable { let bookID: String; let chapterIndex: Int }
    private var retentionTasks: [RetentionTarget: Task<Void, Never>] = [:]
    private var retentionGeneration = UUID()
    private let retainArtifact: (String, Int) async throws -> Void

    init(artifactStore: LocalAudioArtifactStore? = nil,
         retainArtifact: ((String, Int) async throws -> Void)? = nil) {
        let artifacts = artifactStore ?? .shared
        self.retainArtifact = retainArtifact ?? { book, chapter in
            try await artifacts.requestPlaybackRetention(bookID: book, chapterIndex: chapter)
        }
    }

    func resetRetention() {
        lastPlaybackRetentionRequest = nil
        retentionGeneration = UUID()
    }

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
}
