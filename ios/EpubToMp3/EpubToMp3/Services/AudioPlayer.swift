#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import AVFoundation
import MediaPlayer
import Observation

/// Allowed playback rates surfaced in `PlayerView`.
/// Anything outside this list collapses to 1.0.
enum PlaybackRate: Float, CaseIterable, Identifiable {
    case x075 = 0.75
    case x100 = 1.0
    case x125 = 1.25
    case x150 = 1.5
    case x175 = 1.75
    case x200 = 2.0

    var id: Float { rawValue }
    var label: String { String(format: "%.2fx", rawValue) }
}

/// Thin wrapper around `AVQueuePlayer` that turns a `JobSnapshot` into
/// a chapter playlist + Now Playing / lock-screen integration.
///
/// Why `AVQueuePlayer` and not `AVPlayer`/`AVAudioPlayer`?
///   - `AVAudioPlayer` is single-file, no queue, no streaming.
///   - `AVPlayer` requires manual KVO + replaceCurrentItem juggling for
///     gapless transitions. `AVQueuePlayer` does that for us.
///
/// The audio session must be configured on app launch (see
/// `EpubToMp3App.configureAudioSession`). This class assumes that has
/// already been done — it does NOT call `setActive(true)` itself, because
/// doing so on every player rebuild causes glitches when another media
/// app is active.
@Observable
@MainActor
final class AudioPlayer {

    // MARK: Public observable state

    private(set) var snapshot: JobSnapshot?
    private(set) var currentChapterIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var rate: PlaybackRate = .x100
    private(set) var positionSeconds: TimeInterval = 0
    private(set) var durationSeconds: TimeInterval = 0

    // MARK: AsyncStreams (positions + chapter changes)

    private var chapterContinuations: [UUID: AsyncStream<JobSnapshot.Chapter?>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<TimeInterval>.Continuation] = [:]

    var currentChapter: AsyncStream<JobSnapshot.Chapter?> {
        AsyncStream { continuation in
            let id = UUID()
            self.chapterContinuations[id] = continuation
            continuation.yield(self.currentChapterValue)
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.chapterContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// Position stream — debounced to ~250ms by sampling on a periodic
    /// time observer (`AVPlayer.addPeriodicTimeObserver` interval = 0.25s).
    var position: AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let id = UUID()
            self.positionContinuations[id] = continuation
            continuation.yield(self.positionSeconds)
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.positionContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: Internals

    private let resumeStore: ResumeStore
    private let backendBaseURL: URL?
    private var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var lastResumePersist: Date = .distantPast

    init(resumeStore: ResumeStore = ResumeStore(), backendBaseURL: URL? = nil) {
        self.resumeStore = resumeStore
        self.backendBaseURL = backendBaseURL
        configureRemoteCommands()
    }

    deinit {
        // We can't touch @MainActor isolated state from deinit on Swift 6;
        // the observer tokens are local to the player instance which is
        // released here, so AVFoundation cleans up naturally.
    }

    // MARK: Public API

    func play(snapshot: JobSnapshot, startingAt chapterIndex: Int = 0) {
        teardownPlayer()
        self.snapshot = snapshot

        let chapters = snapshot.playableChapters
        let safeIndex = max(0, min(chapterIndex, chapters.count - 1))
        guard !chapters.isEmpty else { return }

        let items = chapters.compactMap { chapter -> AVPlayerItem? in
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl) else { return nil }
            return AVPlayerItem(url: absolute)
        }
        guard !items.isEmpty else { return }

        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        // Skip to the requested chapter by advancing the queue head.
        for _ in 0..<safeIndex { queue.advanceToNextItem() }
        self.player = queue
        self.currentChapterIndex = safeIndex

        attachObservers()

        // Restore prior position for this chapter, if any.
        if let marker = resumeStore.marker(jobId: snapshot.jobId, chapterIndex: safeIndex),
           marker.positionSeconds > 1.0 {
            queue.seek(to: CMTime(seconds: marker.positionSeconds, preferredTimescale: 600))
        }

        queue.rate = rate.rawValue
        queue.play()
        isPlaying = true
        publishCurrentChapter()
        updateNowPlayingInfo()
    }

    /// Live-update the snapshot. Used by `PlayerReaderView`'s SSE
    /// subscription so newly-finished chapters can be appended to the
    /// AVQueuePlayer without interrupting the chapter currently playing.
    /// We do NOT replace existing items — that would skip back to chapter
    /// 0 and break the playhead.
    func updateSnapshot(_ newSnapshot: JobSnapshot) {
        guard let queue = player else {
            // No player yet — defer to the caller's normal `play()` flow.
            self.snapshot = newSnapshot
            return
        }

        let oldCount = self.snapshot?.playableChapters.count ?? 0
        let newChapters = newSnapshot.playableChapters
        self.snapshot = newSnapshot

        guard newChapters.count > oldCount else {
            updateNowPlayingInfo()
            return
        }

        // Append every chapter that wasn't in the queue yet. AVQueuePlayer
        // requires `canInsert(_:after:)` to be true; if Apple ever rejects
        // an item we just stop appending and surface what we have.
        let toAppend = newChapters.suffix(newChapters.count - oldCount)
        for chapter in toAppend {
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl) else { continue }
            let item = AVPlayerItem(url: absolute)
            if queue.canInsert(item, after: nil) {
                queue.insert(item, after: nil)
            }
        }
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        persistResumePoint(force: true)
        updateNowPlayingInfo()
    }

    func resume() {
        guard let player else { return }
        player.rate = rate.rawValue
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        positionSeconds = max(0, seconds)
        broadcastPosition()
        updateNowPlayingInfo()
    }

    func nextChapter() {
        guard let player, let snapshot else { return }
        let chapters = snapshot.playableChapters
        guard currentChapterIndex + 1 < chapters.count else { return }
        player.advanceToNextItem()
        currentChapterIndex += 1
        positionSeconds = 0
        publishCurrentChapter()
        updateNowPlayingInfo()
    }

    func previousChapter() {
        // AVQueuePlayer doesn't support backwards traversal natively. If we're
        // > 3s into the current chapter, treat "previous" as a restart;
        // otherwise rebuild the queue starting at index-1.
        if positionSeconds > 3 {
            seek(to: 0)
            return
        }
        guard let snapshot, currentChapterIndex > 0 else {
            seek(to: 0)
            return
        }
        play(snapshot: snapshot, startingAt: currentChapterIndex - 1)
    }

    func setRate(_ rate: PlaybackRate) {
        self.rate = rate
        if let player, isPlaying { player.rate = rate.rawValue }
        updateNowPlayingInfo()
    }

    // MARK: Observers

    private func attachObservers() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.positionSeconds = time.seconds.isFinite ? time.seconds : 0
                if let item = player.currentItem {
                    let dur = item.duration.seconds
                    self.durationSeconds = dur.isFinite ? dur : 0
                }
                self.broadcastPosition()
                self.persistResumePoint(force: false)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let snapshot = self.snapshot else { return }
                let chapters = snapshot.playableChapters
                if self.currentChapterIndex + 1 < chapters.count {
                    self.currentChapterIndex += 1
                    self.positionSeconds = 0
                    self.publishCurrentChapter()
                    self.updateNowPlayingInfo()
                } else {
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }

    // MARK: Now Playing / Remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentChapterValue?.displayTitle ?? "Chapter"
        info[MPMediaItemPropertyAlbumTitle] = snapshot?.bookTitle ?? "EpubToMp3"
        info[MPMediaItemPropertyArtist] = snapshot?.bookAuthor ?? ""
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
        info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate.rawValue : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Helpers

    private var currentChapterValue: JobSnapshot.Chapter? {
        guard let chapters = snapshot?.playableChapters,
              currentChapterIndex < chapters.count else { return nil }
        return chapters[currentChapterIndex]
    }

    private func publishCurrentChapter() {
        let value = currentChapterValue
        for cont in chapterContinuations.values { cont.yield(value) }
    }

    private func broadcastPosition() {
        for cont in positionContinuations.values { cont.yield(positionSeconds) }
    }

    private func persistResumePoint(force: Bool) {
        guard let snapshot else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastResumePersist) < 5 { return }
        lastResumePersist = now
        resumeStore.save(
            jobId: snapshot.jobId,
            chapterIndex: currentChapterIndex,
            position: positionSeconds,
            now: now
        )
    }

    /// Resolve a backend-relative download path (e.g. `/api/outputs/<jobId>/<file>.mp3`)
    /// to an absolute URL the iOS player can fetch. If `path` is already
    /// absolute (starts with `http`), use it as-is.
    private func absoluteURL(forDownloadPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard let baseURL = backendBaseURL else { return URL(string: path) }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
#endif
