import Foundation
import AVFoundation
import MediaPlayer
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private let audioLog = Logger(subsystem: "epub2mp3", category: "AudioPlayer")

/// Allowed playback rates surfaced in `PlayerView`.
/// Anything outside this list collapses to 1.0.
enum PlaybackRate: Float, CaseIterable, Identifiable {
    case x050 = 0.5
    case x075 = 0.75
    case x100 = 1.0
    case x125 = 1.25
    case x150 = 1.5
    case x175 = 1.75
    case x200 = 2.0

    var id: Float { rawValue }

    /// Short label shown inline on the rate button (e.g. "1x", "1.25x").
    var shortLabel: String {
        switch self {
        case .x050: return "0.5x"
        case .x075: return "0.75x"
        case .x100: return "1x"
        case .x125: return "1.25x"
        case .x150: return "1.5x"
        case .x175: return "1.75x"
        case .x200: return "2x"
        }
    }

    /// Longer label used in segmented pickers / accessibility.
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
@MainActor
final class AudioPlayer: ObservableObject {

    /// UserDefaults key holding the `BookEntity.id` of the book that was
    /// most recently surfaced in `NowPlayingView`. Written by the view
    /// when the user begins playback so the landing screen rehydrates
    /// after a cold launch. Centralised here so the rest of the app
    /// shares a single source of truth.
    static let currentBookIDDefaultsKey = "currentlyPlayingBookID"
    /// Companion key — zero-based chapter index of the resumed book.
    static let currentChapterIndexDefaultsKey = "currentlyPlayingChapterIndex"
    /// Channel where the reader publishes the chapter the USER is
    /// currently reading (vs the chapter the audio is narrating). The
    /// mini-player / full-player compare these two indices on a play
    /// tap and, when they disagree, surface a three-option dialog so
    /// the user can choose what to start: current page, where they
    /// stopped, or the beginning.
    static let readerCurrentChapterIndexDefaultsKey = "readerCurrentChapterIndex"
    /// Companion channel — fraction (0.0 … 1.0) of how far into the
    /// current chapter the user has scrolled (paginated mode: page
    /// start char / total chars; scroll mode: contentOffset / contentSize).
    /// Read by `startFromReaderPage` so "From the current page"
    /// actually lands near the user's reading position instead of
    /// the chapter start. Stored as `Double` (UserDefaults does the
    /// `NSNumber` boxing).
    static let readerCurrentPageRatioDefaultsKey = "readerCurrentPageRatio"
    /// Companion channel — id of the first sentence on the user's
    /// currently-visible page. When the active chapter has timing
    /// data injected via `setSentenceTiming`, `startFromReaderPage`
    /// prefers this precise sentence anchor over the ratio
    /// approximation. Cleared on chapter change.
    static let readerCurrentSentenceIdDefaultsKey = "readerCurrentSentenceId"

    // MARK: Public observable state

    @Published private(set) var snapshot: JobSnapshot?
    @Published private(set) var currentChapterIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var rate: PlaybackRate = .x100
    @Published private(set) var positionSeconds: TimeInterval = 0
    @Published private(set) var durationSeconds: TimeInterval = 0

    /// Active sentence ID in sentence-per-segment mode. Updated when the
    /// AVQueuePlayer advances to the next item. `nil` in snapshot mode.
    @Published private(set) var activeSentenceId: String?

    /// Set to `true` by `setSleepTimer(seconds:)` / `cancelSleepTimer()` to
    /// abort an in-progress `performSleepTimerFadeOut` task before it calls
    /// `pause()`. Reset to `false` when the fade completes or is aborted.
    private var sleepTimerCancelled = false
    /// Non-nil while a fade-out task is running; prevents double-fade if
    /// `tickSleepTimer` fires twice in the same 250 ms window.
    private var fadeOutTask: Task<Void, Never>?

    /// `true` while a TTS conversion job is actively running for the
    /// currently-open book. Set by `BookOpenView` / `InstantReaderView`
    /// when they submit or reattach to a conversion job and cleared
    /// when the job reaches a terminal state. Does NOT imply the
    /// player has a loaded audio item — use `firstChapterReady` for that.
    @Published var isConverting: Bool = false

    /// 0.0–1.0 fraction of chapters whose audio is ready, or `nil`
    /// when total chapter count is unknown. Drives the conversion
    /// progress indicator in `MiniPlayerBar` and `InstantReaderView`.
    @Published var conversionProgress: Double? = nil

    /// Becomes `true` as soon as the first chapter MP3 is available
    /// (i.e. `snapshot.playableChapters` becomes non-empty for the
    /// first time). Once `true` it never goes back to `false` for the
    /// same book session so the transport controls are never hidden
    /// after they have appeared.
    @Published private(set) var firstChapterReady: Bool = false

    /// Becomes `true` as soon as the *first audio segment* of the
    /// current chapter has been enqueued via `enqueueSegment(data:…)`.
    /// This fires earlier than `firstChapterReady` (which waits for the
    /// whole chapter MP3) — typically within 500 ms of synthesis start —
    /// satisfying the HIG < 3 s time-to-first-byte requirement.
    /// One-way latch: once `true` it stays `true` for the session.
    @Published private(set) var firstSegmentReady: Bool = false

    /// `true` while the player is buffering / waiting for the current
    /// chapter's audio to become ready. Used by `MiniPlayerBar` and
    /// `FullPlayerSheet` to show a spinner in place of play/pause.
    /// Derived from `isConverting` + `firstChapterReady` so it costs
    /// no extra KVO wiring.
    var isLoading: Bool { isConverting && !firstChapterReady }

    /// Optional cover art bytes (PNG/JPEG). Surfaced to the system
    /// Now Playing widget so lock screen / Control Center / AirPods
    /// menu show the book cover instead of a generic glyph.
    @Published var coverArtData: Data?

    /// Sleep-timer state. When > 0, playback auto-pauses after this
    /// many wall-clock seconds. Decremented by the time observer.
    @Published private(set) var sleepTimerRemaining: TimeInterval = 0
    private var sleepTimerExpiresAt: Date?

    /// Ordered list of playback rates available in the UI.
    let availableRates: [Float] = PlaybackRate.allCases.map(\.rawValue)

    // MARK: AsyncStreams (positions + chapter changes)

    private var chapterContinuations: [UUID: AsyncStream<JobSnapshot.Chapter?>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<TimeInterval>.Continuation] = [:]

    var currentChapter: AsyncStream<JobSnapshot.Chapter?> {
        AsyncStream { continuation in
            let id = UUID()
            // Capture the initial value before the Task hop so we yield
            // the correct snapshot even if the caller subscribes during
            // a mid-update window.
            let initial = self.currentChapterValue
            Task { @MainActor in
                self.chapterContinuations[id] = continuation
                continuation.yield(initial)
            }
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
            let initial = self.positionSeconds
            Task { @MainActor in
                self.positionContinuations[id] = continuation
                continuation.yield(initial)
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.positionContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: Internals

    /// Temp directory for segment MP3 files written by `enqueueSegment`.
    /// Created lazily; cleaned up in `teardownPlayer()`.
    private var segmentTempDir: URL?

    private let resumeStore: ResumeStore
    /// Resolved backend base URL used to turn relative `downloadUrl`
    /// paths into absolute fetch URLs. Mutable so the host view can
    /// reconfigure an already-instantiated player after the sidecar
    /// finishes booting (we keep the same `ObservableObject` instance
    /// across reconfigurations so `@StateObject` subscriptions stay
    /// live).
    var backendBaseURL: URL?
    // `nonisolated(unsafe)` so `deinit` (which is non-isolated on a
    // `@MainActor` class under Swift 6) can read these to detach
    // observers before the wrapper is freed. The tokens themselves
    // are opaque `Any` / `NSObjectProtocol` references safe to release
    // off-main; the AVQueuePlayer is also fine to teardown from any
    // thread (AVFoundation handles its own internal serialisation).
    nonisolated(unsafe) private var player: AVQueuePlayer?
    nonisolated(unsafe) private var timeObserverToken: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    /// KVO token for `AVQueuePlayer.currentItem`. Fires whenever the queue
    /// advances to the next item (including auto-advance at natural end) so
    /// `MPNowPlayingInfoCenter` is always refreshed with the correct chapter
    /// title and duration — even when the OS advances the item before our
    /// `AVPlayerItemDidPlayToEndTime` handler runs.
    nonisolated(unsafe) private var currentItemObserver: NSKeyValueObservation?
    private var lastResumePersist: Date = .distantPast
    /// Throttle for `MPNowPlayingInfoCenter` updates — we update at most
    /// once per second so the lock-screen scrubber stays fresh without
    /// hitting the system's info center on every 250ms tick.
    private var lastNowPlayingUpdate: Date = .distantPast
    private var audioSessionConfigured = false

    // Segment-mode cumulative position tracking: AVQueuePlayer reports
    // per-item position, but SyncEngine needs chapter-relative time.
    private var isSegmentMode = false
    private var segmentChapterIndex: Int = -1
    private var segmentCumulativeBase: TimeInterval = 0
    /// Maps segment queue position → sentence ID. When non-empty,
    /// `activeSentenceId` tracks which sentence is playing by counting
    /// AVPlayerItemDidPlayToEndTime firings.
    private var segmentSentenceIds: [String] = []
    private var segmentPlayedCount: Int = 0

    private static let maxQueueAhead = 5
    private var pendingSegments: [(url: URL, chapterIndex: Int, segmentIndex: Int)] = []

    private var remoteCommandsConfigured = false

    init(resumeStore: ResumeStore = ResumeStore(), backendBaseURL: URL? = nil) {
        self.resumeStore = resumeStore
        self.backendBaseURL = backendBaseURL
    }

    deinit {
        // `deinit` on a `@MainActor` class is implicitly non-isolated
        // under Swift 6 — but the observer tokens declared
        // `nonisolated(unsafe)` are safe to detach from any thread.
        // Apple's docs are emphatic: `addPeriodicTimeObserver` MUST be
        // matched by `removeTimeObserver` before the player is freed
        // or the periodic block can fire against a dangling pointer
        // (FB7359919). NotificationCenter observer must also be
        // removed manually — the framework retains it strongly.
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        currentItemObserver?.invalidate()
        // The AVQueuePlayer is released immediately after this deinit
        // returns — no need to pause it. AVFoundation tears down its
        // own state when refcount hits zero.
    }

    // MARK: Remote commands (lazy — deferred to first playback)

    private func ensureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        configureRemoteCommands()
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    // MARK: Audio session (lazy)

    private func ensureAudioSession() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback, mode: .spokenAudio,
                policy: .longFormAudio,
                options: [.allowBluetoothA2DP, .allowAirPlay]
            )
            // Pause when headphones are unplugged / route is disconnected
            // (e.g. AirPods removed) — prevents unexpected speaker bleed.
            if #available(iOS 17.0, *) {
                try session.setPrefersInterruptionOnRouteDisconnect(true)
            }
            try session.setActive(true, options: [])
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {}
        }
        #endif
    }

    // MARK: Public API

    func setSnapshot(_ snapshot: JobSnapshot) {
        self.snapshot = snapshot
        updateNowPlayingInfo()
    }

    /// Build the AVQueuePlayer for `snapshot` starting at `chapterIndex`, but
    /// **do not** start playback. Audio only begins after an explicit user
    /// action: tapping the Play button, the lock-screen play control, or the
    /// widget toggle (all of which route through `resume()` /
    /// `togglePlayPause()`).
    ///
    /// Historical note: this method used to call `queue.play()` and set
    /// `isPlaying = true`, which meant every view-appear path (reader open,
    /// player sheet, instant reader) silently kicked off audio. That violated
    /// the principle that media should never auto-start without user intent.
    func play(snapshot: JobSnapshot, startingAt chapterIndex: Int = 0) {
        ensureRemoteCommands()
        // Audio session is intentionally NOT activated here — `setActive(true)`
        // on a `.playback` / `.longFormAudio` session interrupts other apps
        // (Spotify, Apple Music, podcast apps) even when our queue is paused.
        // We defer activation to `resume()` so silence on the user's side
        // never costs them their currently-playing audio.
        audioLog.debug("[load] snapshot jobId=\(snapshot.jobId) chapterIndex=\(chapterIndex) playableChapters=\(snapshot.playableChapters.count)")
        let wasPlaying = isPlaying
        teardownPlayer()
        isSegmentMode = false
        segmentCumulativeBase = 0
        segmentSentenceIds = []
        segmentPlayedCount = 0
        activeSentenceId = nil
        self.snapshot = snapshot

        let chapters = snapshot.playableChapters
        let safeIndex = max(0, min(chapterIndex, chapters.count - 1))
        guard !chapters.isEmpty else {
            audioLog.warning("[load] no playable chapters — player not started")
            return
        }

        // Build the queue starting AT `safeIndex` rather than building
        // the full list and walking `advanceToNextItem()` to skip
        // forward. For a 200-chapter book jumping to chapter 150 the
        // old approach allocated 150 AVPlayerItems and fired 150 KVO
        // ticks on `currentItem` before any audio played; the slice
        // approach allocates the 50 items we actually need and is O(1).
        let remaining = chapters[safeIndex...]
        let items = remaining.compactMap { chapter -> AVPlayerItem? in
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl) else { return nil }
            return AVPlayerItem(url: absolute)
        }
        guard !items.isEmpty else { return }

        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        self.player = queue
        self.currentChapterIndex = safeIndex

        attachObservers()

        // Restore prior position for this chapter, if any.
        if let marker = resumeStore.marker(jobId: snapshot.jobId, chapterIndex: safeIndex),
           marker.positionSeconds > 1.0 {
            queue.seek(to: CMTime(seconds: marker.positionSeconds, preferredTimescale: 600))
        }

        // Queue is paused at rate 0 (default). Lock-screen / widget / in-app
        // play controls call `resume()` to start playback.
        queue.rate = 0
        isPlaying = false
        // If the previous snapshot was already playing (e.g. user jumped to a
        // new chapter while listening), preserve that intent.
        if wasPlaying {
            queue.rate = rate.rawValue
            isPlaying = true
        }
        // Re-register for remote-control events so the lock-screen play
        // button works even when we never auto-started. Idempotent.
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
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
        // Activate the audio session lazily, only when the user actually
        // starts playback (Play button, lock-screen control, widget toggle).
        // This is what claims the audio focus from Spotify / Apple Music /
        // etc. — doing it earlier (e.g. on book open) interrupts other
        // apps even though we never produce a sound.
        ensureAudioSession()
        player.rate = rate.rawValue
        isPlaying = true
        updateNowPlayingInfo()
    }

    // MARK: Play-tap routing (centralised so every UI surface — mini
    // player, full player, in-line buttons in the reader — uses the
    // same divergence detection / start-options behaviour. Adding a new
    // play button anywhere in the app should only require wiring
    // `playTapDecision(readerChapterIndex:)` + `startFromReaderPage(_:)`
    // + `startFromBeginning()` — never duplicate the conditional logic.)

    /// What an in-app play-button tap should do, given the chapter the
    /// reader is currently displaying. UI surfaces consult this and
    /// then either toggle, resume, or present the divergence dialog.
    /// Lock-screen / widget / remote-command paths bypass this entirely
    /// — they cannot show a dialog, so they hit `resume()` directly.
    enum PlayTapDecision {
        /// Audio is already playing — flip to pause.
        case pause
        /// No divergence (or no snapshot yet) — straight resume.
        case resume
        /// Reader sits on a different chapter than the audio. The UI
        /// surface should show a 3-option confirmation dialog
        /// (current page / where stopped / beginning).
        case offerStartChoice
    }

    func playTapDecision(readerChapterIndex: Int) -> PlayTapDecision {
        if isPlaying { return .pause }
        guard snapshot != nil else { return .resume }
        return readerChapterIndex != currentChapterIndex
            ? .offerStartChoice
            : .resume
    }

    /// Per-chapter sentence-id → audio-ms timing maps. Populated by the
    /// `SentenceSyncEngine` host (PlayerReaderView) when it loads a
    /// chapter. Lookup is cheap and only used by `startFromReaderPage`
    /// when a precise sentence-anchored seek is preferred over the
    /// char-uniform ratio approximation. Capped at the most-recent ~8
    /// chapters to keep memory bounded.
    private var sentenceTimingByChapter: [Int: [String: Int]] = [:]
    private var sentenceTimingOrder: [Int] = []
    private static let sentenceTimingCacheSize = 8

    /// Inject a sentence-id → start-ms map for `chapterIndex` (which
    /// is a playable-chapter index, same space as `currentChapterIndex`).
    /// Idempotent; pass an empty dictionary to clear.
    func setSentenceTiming(_ map: [String: Int], forChapterIndex chapterIndex: Int) {
        if map.isEmpty {
            sentenceTimingByChapter.removeValue(forKey: chapterIndex)
            sentenceTimingOrder.removeAll { $0 == chapterIndex }
            return
        }
        sentenceTimingByChapter[chapterIndex] = map
        sentenceTimingOrder.removeAll { $0 == chapterIndex }
        sentenceTimingOrder.append(chapterIndex)
        while sentenceTimingOrder.count > Self.sentenceTimingCacheSize {
            let evict = sentenceTimingOrder.removeFirst()
            sentenceTimingByChapter.removeValue(forKey: evict)
        }
    }

    /// "From the current page" branch of the divergence dialog. Loads
    /// the snapshot at the reader's chapter, then seeks (in priority
    /// order):
    /// 1. **`sentenceId`** + injected timing → precise per-sentence
    ///    seek using `SentenceSyncEngine`-grade data.
    /// 2. **`sentenceOffsetRatio`** + known `durationSeconds` →
    ///    char-uniform approximation.
    /// 3. **fallback** → seek to 0 (chapter start).
    ///
    /// The seek can be issued *before* `durationSeconds` is published
    /// (AVPlayer reports it asynchronously after asset preparation).
    /// For the ratio path we therefore stash a pending seek that fires
    /// when the duration finally lands — see `applyPendingProportionalSeek`.
    func startFromReaderPage(
        _ readerChapterIndex: Int,
        sentenceId: String? = nil,
        sentenceOffsetRatio: Double? = nil
    ) {
        guard let snapshot else { resume(); return }
        let target = max(0, min(readerChapterIndex, snapshot.playableChapters.count - 1))
        play(snapshot: snapshot, startingAt: target)

        // Priority 1: sentence-level seek (precise).
        if let sentenceId,
           let map = sentenceTimingByChapter[target],
           let startMs = map[sentenceId] {
            seek(to: TimeInterval(startMs) / 1000.0)
            pendingProportionalSeek = nil
            resume()
            return
        }

        // Priority 2: ratio-based seek, deferred if duration not ready.
        if let ratio = sentenceOffsetRatio, ratio > 0 {
            if durationSeconds > 0 {
                seek(to: max(0, min(1, ratio)) * durationSeconds)
                pendingProportionalSeek = nil
            } else {
                pendingProportionalSeek = ratio
            }
            resume()
            return
        }

        seek(to: 0)
        pendingProportionalSeek = nil
        resume()
    }

    /// Pending fractional-position seek (0…1) waiting for
    /// `durationSeconds` to be published by the asset prepare. Applied
    /// by the time observer the first time `durationSeconds > 0` is
    /// observed after a `startFromReaderPage` ratio path.
    private var pendingProportionalSeek: Double?

    /// Called from the periodic time observer when `durationSeconds`
    /// transitions to a positive value. No-op when no ratio seek is
    /// pending.
    func applyPendingProportionalSeek() {
        guard let ratio = pendingProportionalSeek, durationSeconds > 0 else { return }
        seek(to: max(0, min(1, ratio)) * durationSeconds)
        pendingProportionalSeek = nil
    }

    /// "From the beginning" branch — chapter 0, position 0.
    func startFromBeginning() {
        guard let snapshot else { resume(); return }
        play(snapshot: snapshot, startingAt: 0)
        seek(to: 0)
        resume()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        positionSeconds = max(0, seconds)
        broadcastPosition()
        updateNowPlayingInfo()
    }

    func nextChapter() {
        guard let player else { return }
        if let snapshot {
            let chapters = snapshot.playableChapters
            guard currentChapterIndex + 1 < chapters.count else { return }
        }
        player.advanceToNextItem()
        currentChapterIndex += 1
        positionSeconds = 0
        publishCurrentChapter()
        updateNowPlayingInfo()
    }

    func previousChapter() {
        if positionSeconds > 3 {
            seek(to: 0)
            return
        }
        guard currentChapterIndex > 0 else {
            seek(to: 0)
            return
        }
        if let snapshot {
            play(snapshot: snapshot, startingAt: currentChapterIndex - 1)
        } else {
            seek(to: 0)
        }
    }

    func setRate(_ rate: PlaybackRate) {
        self.rate = rate
        if let player, isPlaying { player.rate = rate.rawValue }
        updateNowPlayingInfo()
    }

    /// Skip relative to the current playhead. Negative values rewind,
    /// positive fast-forward. Clamped to [0, duration].
    func skip(by deltaSeconds: TimeInterval) {
        let target = max(0, min(durationSeconds, positionSeconds + deltaSeconds))
        seek(to: target)
    }

    /// Segment-streaming ingestion point. Called by `PythonBridge` after
    /// each TTS chunk closes, before the full chapter MP3 is written.
    ///
    /// - Parameters:
    ///   - data: Raw MP3 bytes for this segment (Edge emits ID3-less MP3
    ///     frames; raw-byte append is valid — same trick as the sidecar).
    ///   - chapterIndex: Zero-based chapter index this segment belongs to.
    ///   - segmentIndex: Zero-based segment index within the chapter.
    ///
    /// Behaviour:
    /// 1. Writes `data` to a numbered temp file so `AVPlayerItem` can
    ///    reference a stable URL (AVFoundation requires file-backed URLs
    ///    for local MP3; it does not accept in-memory `Data`).
    /// 2. Creates an `AVPlayerItem` and inserts it at the end of the queue.
    /// 3. If this is the first segment ever, starts playback automatically
    ///    and sets `firstSegmentReady = true`.
    ///
    /// Thread-safety: must be called on the main actor (same as all other
    /// AudioPlayer methods).
    func enqueueSegment(data: Data, chapterIndex: Int, segmentIndex: Int, sentenceId: String? = nil) {
        ensureRemoteCommands()
        // Only activate the audio session if the user is already playing.
        // While conversion streams in the background, we may receive
        // dozens of segments before the user even taps Play — claiming
        // the audio focus on every one of them silently mutes Spotify /
        // Music. The session is activated by `resume()` the moment the
        // user does tap Play, and `enqueueSegment` will skip the
        // activation here on subsequent ticks because
        // `audioSessionConfigured` is sticky.
        if isPlaying { ensureAudioSession() }
        audioLog.debug("[enqueueSegment] ch=\(chapterIndex) seg=\(segmentIndex) bytes=\(data.count) playerNil=\(self.player == nil)")
        guard !data.isEmpty else {
            audioLog.warning("[enqueueSegment] empty data ignored ch=\(chapterIndex) seg=\(segmentIndex)")
            return
        }

        // Ensure a temp directory exists for this session.
        if segmentTempDir == nil {
            segmentTempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("epub2mp3-segments-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: segmentTempDir!, withIntermediateDirectories: true
            )
        }
        guard let tmpDir = segmentTempDir else { return }

        let segFile = tmpDir.appendingPathComponent(
            "ch\(chapterIndex)-seg\(segmentIndex).mp3"
        )
        do {
            try data.write(to: segFile)
        } catch {
            // Non-fatal: segment is lost but subsequent ones still arrive.
            return
        }

        isSegmentMode = true
        if chapterIndex != segmentChapterIndex {
            segmentCumulativeBase = 0
            segmentChapterIndex = chapterIndex
            segmentSentenceIds = []
            segmentPlayedCount = 0
            currentChapterIndex = chapterIndex
        }
        if let sentenceId {
            segmentSentenceIds.append(sentenceId)
            if segmentSentenceIds.count == 1 { activeSentenceId = sentenceId }
        }

        if player == nil {
            let item = AVPlayerItem(url: segFile)
            let queue = AVQueuePlayer(items: [item])
            queue.actionAtItemEnd = .advance
            self.player = queue
            self.currentChapterIndex = chapterIndex
            attachObservers()
            // Only auto-start the first segment if the user had already
            // expressed intent to play (e.g. tapped Play while waiting for
            // the conversion to produce the first chunk). Otherwise we set
            // everything up but stay paused — the next user tap on Play /
            // lock-screen / widget will call `resume()`.
            if isPlaying {
                queue.rate = rate.rawValue
            } else {
                queue.rate = 0
            }
            #if os(iOS)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif
            audioLog.debug("[enqueueSegment] AVQueuePlayer created (isPlaying=\(self.isPlaying)). items=\(queue.items().count) rate=\(queue.rate) currentItemNil=\(queue.currentItem == nil)")
            publishCurrentChapter()
            updateNowPlayingInfo()
        } else if let queue = player {
            let queueCount = queue.items().count
            if queueCount < Self.maxQueueAhead {
                let item = AVPlayerItem(url: segFile)
                if queue.canInsert(item, after: nil) {
                    queue.insert(item, after: nil)
                    audioLog.debug("[enqueueSegment] appended to queue, total=\(queue.items().count)")
                }
            } else {
                self.pendingSegments.append((url: segFile, chapterIndex: chapterIndex, segmentIndex: segmentIndex))
                audioLog.debug("[enqueueSegment] deferred ch=\(chapterIndex) seg=\(segmentIndex), pending=\(self.pendingSegments.count)")
            }
        }

        if !firstSegmentReady {
            firstSegmentReady = true
            // Also raise firstChapterReady so MiniPlayerBar shows play/pause.
            firstChapterReady = true
        }
        conversionStatus.record(.chunkComplete,
            "ch\(chapterIndex) segment \(segmentIndex) ready (\(data.count) bytes)")
    }

    private func drainPendingSegments() {
        guard let queue = player, !pendingSegments.isEmpty else { return }
        while queue.items().count < Self.maxQueueAhead, !pendingSegments.isEmpty {
            let next = pendingSegments.removeFirst()
            let item = AVPlayerItem(url: next.url)
            if queue.canInsert(item, after: nil) {
                queue.insert(item, after: nil)
                audioLog.debug("[drainPending] enqueued ch=\(next.chapterIndex) seg=\(next.segmentIndex), queue=\(queue.items().count) pending=\(self.pendingSegments.count)")
            }
        }
    }

    /// Called by `BookOpenView` / `InstantReaderView` when the first
    /// playable chapter MP3 lands. Sets `firstChapterReady = true` and
    /// clears `isConverting` only if the snapshot is already terminal
    /// (all chapters done). Idempotent — safe to call multiple times.
    func markFirstChapterReady() {
        firstChapterReady = true
        conversionStatus.record(.chapterComplete, "First chapter audio ready")
    }

    /// Record a conversion error in the status log. Called by
    /// `BookOpenView` when a chapter synthesis fails so the user can
    /// see the error in `ConversionStatusSheet` and tap Retry.
    func recordConversionError(_ message: String) {
        conversionStatus.record(.error, message)
    }

    /// Live conversion event log. Populated by `enqueueSegment`,
    /// `markFirstChapterReady`, and error paths in `BookOpenView`.
    /// Observed by `ConversionStatusSheet` so the user can inspect
    /// segment-level progress without leaving the reader.
    let conversionStatus = ConversionStatus()

    /// Reset conversion-tracking state when a new book session starts
    /// so stale progress from a previous book is never shown.
    func clearConversionState() {
        isConverting = false
        conversionProgress = nil
        if !isPlaying && player == nil {
            firstChapterReady = false
            firstSegmentReady = false
        }
        conversionStatus.endSession()
    }

    /// Tear down the player completely and clear the Now Playing widget.
    /// Call this when the reader session ends so the lock screen no
    /// longer shows stale metadata for a book that is no longer active.
    func stop() {
        teardownPlayer()
        isPlaying = false
        snapshot = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
    }

    /// Set or cancel the sleep timer. Pass 0 to cancel; any positive
    /// value schedules an auto-pause that many seconds from now.
    func setSleepTimer(seconds: TimeInterval) {
        if seconds <= 0 {
            // Abort any running fade-out.
            sleepTimerCancelled = true
            fadeOutTask?.cancel()
            fadeOutTask = nil
            sleepTimerRemaining = 0
            sleepTimerExpiresAt = nil
            return
        }
        sleepTimerCancelled = false
        sleepTimerRemaining = seconds
        sleepTimerExpiresAt = Date().addingTimeInterval(seconds)
    }

    /// Convenience: schedule sleep timer from a whole-minute value.
    /// Pass 0 to cancel.
    func startSleepTimer(minutes: Int) {
        setSleepTimer(seconds: TimeInterval(minutes) * 60)
    }

    /// Cancel any active sleep timer.
    func cancelSleepTimer() {
        setSleepTimer(seconds: 0)
    }

    /// Advance to the next rate in `PlaybackRate.allCases`, wrapping
    /// from the last entry back to the first.
    func cycleRate() {
        let cases = PlaybackRate.allCases
        guard let idx = cases.firstIndex(of: rate) else {
            setRate(.x100)
            return
        }
        let next = cases[(idx + 1) % cases.count]
        setRate(next)
    }

    /// Skip forward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipForward(seconds: Double = 15) {
        skip(by: seconds)
    }

    /// Skip backward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipBackward(seconds: Double = 15) {
        skip(by: -seconds)
    }

    // MARK: Observers

    private func attachObservers() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let rawTime = time.seconds.isFinite ? time.seconds : 0
                self.positionSeconds = self.isSegmentMode
                    ? self.segmentCumulativeBase + rawTime
                    : rawTime
                if let item = player.currentItem {
                    let dur = item.duration.seconds
                    self.durationSeconds = dur.isFinite ? dur : 0
                }
                // Item C — fire a queued proportional seek the first
                // tick after AVPlayer publishes duration. Without this
                // a play tap during "From the current page" right after
                // chapter switch lands at 0 (duration was still NaN at
                // call time).
                self.applyPendingProportionalSeek()
                self.broadcastPosition()
                self.persistResumePoint(force: false)
                self.tickSleepTimer()
                // Refresh lock-screen / Control Center scrubber at ~1 Hz.
                // Calling this on every 250ms tick is wasteful; the system
                // only re-renders the widget at ~1 Hz anyway.
                let now = Date()
                if now.timeIntervalSince(self.lastNowPlayingUpdate) >= 1.0 {
                    self.lastNowPlayingUpdate = now
                    self.updateNowPlayingInfo()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                // `object: nil` above subscribes us to *every* AVPlayerItem
                // ending in the process — share extensions / preview
                // players / other AVPlayers in the same app would
                // trigger this handler with their own items. Filter to
                // items currently owned by OUR queue so we never advance
                // chapters on an unrelated item-end.
                guard
                    let finished = notification.object as? AVPlayerItem,
                    self.player?.items().contains(finished) == true
                else { return }

                if self.isSegmentMode {
                    let dur = finished.duration.seconds
                    if dur.isFinite { self.segmentCumulativeBase += dur }
                    self.segmentPlayedCount += 1
                    if self.segmentPlayedCount < self.segmentSentenceIds.count {
                        self.activeSentenceId = self.segmentSentenceIds[self.segmentPlayedCount]
                    } else {
                        self.activeSentenceId = nil
                    }
                }

                self.drainPendingSegments()
                guard let snapshot = self.snapshot else { return }
                let totalChapters = self.isSegmentMode
                    ? (snapshot.chapterProgress?.count ?? 0)
                    : snapshot.playableChapters.count
                if !self.isSegmentMode, self.currentChapterIndex + 1 < totalChapters {
                    self.currentChapterIndex += 1
                    self.positionSeconds = 0
                    self.publishCurrentChapter()
                    self.updateNowPlayingInfo()
                } else if !self.isSegmentMode {
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
        }
        // KVO on `currentItem` catches auto-advance transitions that happen
        // before the `AVPlayerItemDidPlayToEndTime` notification is delivered
        // (e.g. buffer-ahead promotion on fast devices). It MUST reconcile
        // `currentChapterIndex` to the chapter whose URL backs the new
        // current item before refreshing Now Playing — otherwise the lock
        // screen / control center / widget show the previous chapter's
        // title until the end-of-item notification finally fires.
        //
        // RACE GUARD: drop any queued `pendingProportionalSeek` for the
        // *previous* chapter the instant the queue advances. Without
        // this, the periodic time observer (running every 250 ms) could
        // apply that seek against the NEW chapter's duration → landing
        // at the wrong fractional position. The seek must always belong
        // to the chapter the caller intended at `startFromReaderPage`
        // time, never carry over a chapter boundary.
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingProportionalSeek = nil
                self.reconcileChapterIndexFromCurrentItem()
                self.publishCurrentChapter()
                self.updateNowPlayingInfo()
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken { player?.removeTimeObserver(token) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        player?.pause()
        player = nil
        // Remove segment temp files from the previous session. Best-effort:
        // if the OS already cleaned /tmp, the removeItem call is a no-op.
        if let tmpDir = segmentTempDir {
            try? FileManager.default.removeItem(at: tmpDir)
            segmentTempDir = nil
        }
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
        // Skip ±N seconds (Control Center, AirPods double-tap, lock-screen
        // arrow buttons). 15 / 30 are the standard audiobook intervals.
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(by: e.interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(by: -e.interval) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRate.allCases.map { NSNumber(value: $0.rawValue) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent,
                  let rate = PlaybackRate(rawValue: e.playbackRate) else {
                return .commandFailed
            }
            Task { @MainActor in self?.setRate(rate) }
            return .success
        }
    }

    /// Map `AVQueuePlayer.currentItem` back to the index of the chapter whose
    /// `downloadUrl` produced it. KVO fires before the end-of-item
    /// notification, so this is what keeps the lock-screen title in sync
    /// during auto-advance.
    private func reconcileChapterIndexFromCurrentItem() {
        guard
            let player,
            let item = player.currentItem,
            let urlAsset = item.asset as? AVURLAsset,
            let snapshot
        else { return }
        let chapters = snapshot.playableChapters
        guard let idx = chapters.firstIndex(where: { chapter in
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl) else { return false }
            return absolute == urlAsset.url
        }) else { return }
        guard idx != currentChapterIndex else { return }
        currentChapterIndex = idx
        positionSeconds = 0
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentChapterValue?.displayTitle ?? "Chapter"
        // "Album" maps to the book title; "Artist" maps to the author name.
        info[MPMediaItemPropertyAlbumTitle] = snapshot?.bookTitle ?? "Epub-to-Mp3"
        info[MPMediaItemPropertyArtist] = snapshot?.bookAuthor ?? ""
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
        info[MPMediaItemPropertyPlaybackDuration] = durationSeconds > 0 ? durationSeconds : 0
        // Rate = 0 when paused; actual rate when playing. The system uses
        // this to animate the scrubber in real time on the lock screen.
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate.rawValue : 0.0
        // Default rate tells the lock-screen widget what "1x" means so
        // the rate indicator renders correctly at non-standard speeds.
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if let coverArtData, let artwork = makeArtwork(from: coverArtData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #else
        guard let image = NSImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #endif
    }

    /// Decrement the sleep timer once per time observer tick (~250 ms).
    /// When it reaches zero, start the 10-second fade-out instead of pausing
    /// immediately.
    private func tickSleepTimer() {
        guard let expiry = sleepTimerExpiresAt else { return }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 {
            sleepTimerRemaining = 0
            sleepTimerExpiresAt = nil
            guard fadeOutTask == nil else { return }  // Already fading.
            sleepTimerCancelled = false
            fadeOutTask = Task { @MainActor in
                await performSleepTimerFadeOut()
                self.fadeOutTask = nil
            }
        } else {
            sleepTimerRemaining = remaining
        }
    }

    /// Fade volume from current level to 0 over ~10 seconds (20 steps × 0.5 s),
    /// then pause. Restores original volume so the next session is unaffected.
    /// Aborted immediately if `sleepTimerCancelled` becomes `true` mid-fade.
    ///
    /// Uses `Task.sleep(nanoseconds:)` for macOS 12 compatibility — avoids the
    /// `Task.sleep(for:)` API that requires macOS 13+.
    private func performSleepTimerFadeOut() async {
        guard let player else {
            pause()
            return
        }
        let originalVolume = player.volume
        let steps = 20
        let stepNs: UInt64 = 500_000_000  // 0.5 s × 20 = 10 s total
        for i in stride(from: steps, through: 0, by: -1) {
            guard !sleepTimerCancelled, !Task.isCancelled else {
                // User cancelled: restore volume and bail out.
                player.volume = originalVolume
                return
            }
            player.volume = originalVolume * (Float(i) / Float(steps))
            try? await Task.sleep(nanoseconds: stepNs)
        }
        guard !sleepTimerCancelled else {
            player.volume = originalVolume
            return
        }
        pause()
        player.volume = originalVolume  // Restore for next session.
    }

    // MARK: Helpers

    private var currentChapterValue: JobSnapshot.Chapter? {
        if let all = snapshot?.chapterProgress,
           let match = all.first(where: { $0.index == currentChapterIndex }) {
            return match
        }
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

    func persistResumePoint(force: Bool) {
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
        UserDefaults.standard.set(
            currentChapterIndex,
            forKey: Self.currentChapterIndexDefaultsKey
        )
    }

    /// Resolve a backend-relative download path (e.g. `/api/outputs/<jobId>/<file>.mp3`)
    /// to an absolute URL the iOS player can fetch. If `path` is already
    /// absolute (starts with `http`), use it as-is.
    private func absoluteURL(forDownloadPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard let baseURL = backendBaseURL else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Test hooks
    //
    // Direct setters for state that is `@Published private(set)` or
    // private — used by `AudioPlayerDivergenceTests` to construct the
    // exact state matrix the decision/seek helpers must handle.
    // Strictly compiled-in: not referenced from product code.
    #if DEBUG
    func testHook_setIsPlaying(_ value: Bool) { self.isPlaying = value }
    func testHook_setSnapshot(_ snap: JobSnapshot) { self.snapshot = snap }
    func testHook_setCurrentChapterIndex(_ idx: Int) { self.currentChapterIndex = idx }
    func testHook_setDurationSeconds(_ value: Double) { self.durationSeconds = value }
    func testHook_setPendingProportionalSeek(_ ratio: Double?) {
        self.pendingProportionalSeek = ratio
    }
    func testHook_pendingProportionalSeek() -> Double? { pendingProportionalSeek }
    func testHook_sentenceTimingMap(forChapterIndex idx: Int) -> [String: Int]? {
        sentenceTimingByChapter[idx]
    }
    #endif
}
