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

/// Playback rates surfaced by the horizontal rate picker.
enum PlaybackRate: Float, CaseIterable, Identifiable {
    case x080 = 0.8
    case x100 = 1.0
    case x130 = 1.3
    case x150 = 1.5
    case x180 = 1.8
    case x300 = 3.0
    case x050 = 0.5
    case x060 = 0.6
    case x070 = 0.7
    case x200 = 2.0
    case x220 = 2.2
    case x250 = 2.5
    case x350 = 3.5
    case x400 = 4.0

    var id: Float { rawValue }

    /// Short label shown inline on the rate button (e.g. "1x", "1.25x").
    var shortLabel: String {
        switch self {
        case .x080: return "0.8x"
        case .x100: return "1x"
        case .x130: return "1.3x"
        case .x150: return "1.5x"
        case .x180: return "1.8x"
        case .x300: return "3x"
        case .x050: return "0.5x"
        case .x060: return "0.6x"
        case .x070: return "0.7x"
        case .x200: return "2x"
        case .x220: return "2.2x"
        case .x250: return "2.5x"
        case .x350: return "3.5x"
        case .x400: return "4x"
        }
    }

    /// Longer label used in segmented pickers / accessibility.
    var label: String { shortLabel }

    /// The first visible row of the picker and the list used by the
    /// compact rate-cycle button.
    static let primaryRates: [PlaybackRate] = [
        .x080, .x100, .x130, .x150, .x180, .x300
    ]
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

    @Published private(set) var snapshot: JobSnapshot? {
        didSet { refreshCachedBookChapterProgress() }
    }

    /// Derived from `snapshot`, recomputed only when `snapshot` is reassigned
    /// (once per SSE/poll update), not on every read. The segmented playback
    /// progress bars in the native player poll this from a
    /// `CADisplayLink` at up to 30 fps — reconstructing `BookChapterProgress`
    /// (sort + map + two reduce over every chapter) on each of those ticks
    /// would burn main-thread time on a large book for no reason, since the
    /// underlying data hasn't changed between ticks.
    private(set) var cachedBookChapterProgress: BookChapterProgress?

    private func refreshCachedBookChapterProgress() {
        guard let snapshot, snapshot.chapterProgress?.isEmpty == false else {
            cachedBookChapterProgress = nil
            return
        }
        cachedBookChapterProgress = BookChapterProgress(snapshot: snapshot)
    }

    @Published private(set) var currentChapterIndex: Int = 0
    private var readerChapterTitles: [Int: String] = [:]
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var rate: PlaybackRate = .x100
    /// High-frequency transport state is published by `playbackClock`
    /// instead of this global object. The computed compatibility surface
    /// keeps the player domain API stable while preventing unrelated views
    /// from redrawing on every AVPlayer tick.
    private(set) var positionSeconds: TimeInterval {
        get { playbackClock.positionSeconds }
        set { playbackClock.update(positionSeconds: newValue) }
    }

    private(set) var durationSeconds: TimeInterval {
        get { playbackClock.durationSeconds }
        set { playbackClock.update(durationSeconds: newValue) }
    }

    /// Active sentence ID in sentence-per-segment mode. Updated when the
    /// AVQueuePlayer advances to the next item. `nil` in snapshot mode.
    @Published private(set) var activeSentenceId: String?

    /// Surfaces user-actionable problems from the player without
    /// requiring the caller to wrap every method in `throws`. Set
    /// when a load / playback request fails in a way the user would
    /// notice silence about (e.g. `play(snapshot:)` invoked on an
    /// empty snapshot). Set back to `nil` by the consumer after it
    /// displays the toast / banner. Views observe via @Published.
    @Published var lastError: PlayerError?

    /// Errors the player can surface back to a native controller. Kept
    /// minimal — anything more granular belongs in a category-specific
    /// error type owned by the calling site.
    ///
    /// `Identifiable` so controllers can identify a
    /// new error fired DURING the previous alert's dismiss animation —
    /// the `isPresented:` variant would silently drop it. Using the
    /// raw value as id means setting `lastError = .x` twice in a row
    /// is treated as the same alert (no re-flash); switching to a
    /// different error re-presents.
    enum PlayerError: LocalizedError, Equatable, Identifiable {
        case noPlayableChapters
        case emptySegmentData
        case segmentWriteFailed
        case missingSnapshot

        var id: String {
            switch self {
            case .noPlayableChapters: return "noPlayableChapters"
            case .emptySegmentData: return "emptySegmentData"
            case .segmentWriteFailed: return "segmentWriteFailed"
            case .missingSnapshot: return "missingSnapshot"
            }
        }

        var errorDescription: String? {
            switch self {
            case .noPlayableChapters:
                return L10n.string("player.error.noPlayableChapters")
            case .emptySegmentData:
                return L10n.string("player.error.emptySegmentData")
            case .segmentWriteFailed:
                return L10n.string("player.error.segmentWriteFailed")
            case .missingSnapshot:
                return L10n.string("player.error.missingSnapshot")
            }
        }
    }

    /// Set to `true` by `setSleepTimer(seconds:)` / `cancelSleepTimer()` to
    /// abort an in-progress `performSleepTimerFadeOut` task before it calls
    /// `pause()`. Reset to `false` when the fade completes or is aborted.
    private var sleepTimerCancelled = false
    /// Non-nil while a fade-out task is running; prevents double-fade if
    /// `tickSleepTimer` fires twice in the same 250 ms window.
    private var fadeOutTask: Task<Void, Never>?

    /// `true` while a TTS conversion job is actively running for the
    /// currently-open book. Set by the native reader
    /// when they submit or reattach to a conversion job and cleared
    /// when the job reaches a terminal state. Does NOT imply the
    /// player has a loaded audio item — use `firstChapterReady` for that.
    @Published var isConverting: Bool = false

    /// 0.0–1.0 fraction of chapters whose audio is ready, or `nil`
    /// when total chapter count is unknown. Drives the conversion
    /// progress indicator in the native player and reader.
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
    /// chapter's audio to become ready. Used by native player controllers
    /// to show a spinner in place of play/pause.
    /// Derived from `isConverting` + `firstChapterReady` so it costs
    /// no extra KVO wiring.
    var isLoading: Bool { isConverting && !firstChapterReady }

    /// Optional cover art bytes (PNG/JPEG). Surfaced to the system
    /// Now Playing widget so lock screen / Control Center / AirPods
    /// menu show the book cover instead of a generic glyph.
    @Published var coverArtData: Data?

    /// Sleep-timer state. When > 0, playback auto-pauses after this
    /// many wall-clock seconds. Decremented by the time observer.
    private(set) var sleepTimerRemaining: TimeInterval {
        get { playbackClock.sleepTimerRemaining }
        set { playbackClock.update(sleepTimerRemaining: newValue) }
    }
    private var sleepTimerExpiresAt: Date?

    /// Ordered list of playback rates available in the UI.
    let availableRates: [Float] = PlaybackRate.primaryRates.map(\.rawValue)

    // MARK: AsyncStreams (positions + chapter changes)

    // `nonisolated(unsafe)` so `deinit` (non-isolated under Swift 6
    // on a `@MainActor` class) can drain them. The dictionaries are
    // only mutated from the @MainActor body of `currentChapter` /
    // `position` and from the `onTermination` continuation
    // (already-dispatched to MainActor). At deinit time all weak-self
    // tasks have returned early so no concurrent mutator races.
    nonisolated(unsafe) private var chapterContinuations: [UUID: AsyncStream<JobSnapshot.Chapter?>.Continuation] = [:]
    nonisolated(unsafe) private var positionContinuations: [UUID: AsyncStream<TimeInterval>.Continuation] = [:]

    var currentChapter: AsyncStream<JobSnapshot.Chapter?> {
        AsyncStream { continuation in
            let id = UUID()
            // This property is MainActor-isolated. Register synchronously so
            // the initial value is available before an async consumer starts
            // waiting; an extra actor hop can deadlock async-let consumers.
            chapterContinuations[id] = continuation
            continuation.yield(currentChapterValue)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.chapterContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Position stream — debounced to ~250ms by sampling on a periodic
    /// time observer (`AVPlayer.addPeriodicTimeObserver` interval = 0.25s).
    var position: AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let id = UUID()
            // Register synchronously for deterministic initial delivery and
            // to avoid an actor-hop deadlock with concurrent consumers.
            positionContinuations[id] = continuation
            continuation.yield(positionSeconds)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.positionContinuations.removeValue(forKey: id)
                }
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
    /// finishes booting. The same publisher-backed instance is kept across
    /// reconfigurations so UIKit/AppKit subscriptions remain stable.
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
    private var itemObservationCancellables = Set<AnyCancellable>()
    private var lastResumePersist: Date = .distantPast
    /// Throttle for `MPNowPlayingInfoCenter` updates — we update at most
    /// once per second so the lock-screen scrubber stays fresh without
    /// hitting the system's info center on every 250ms tick.
    private var lastNowPlayingUpdate: Date = .distantPast
    // `nonisolated(unsafe)` (matching `player`/`timeObserverToken`/`endObserver`
    // above) so `deinit` — non-isolated under Swift 6 on a `@MainActor` class —
    // can read/reset it from `releaseSystemPlaybackResources()`. Every mutator
    // besides deinit still runs on MainActor, so there is no concurrent writer.
    nonisolated(unsafe) private var audioSessionConfigured = false
    nonisolated(unsafe) private var audioSessionObserverTokens: [NSObjectProtocol] = []
    /// One removal thunk per `MPRemoteCommandCenter.shared()` `addTarget`
    /// call in `configureRemoteCommands()`, each closing over the exact
    /// command + opaque target token it belongs to. `MPRemoteCommandCenter`
    /// is a process-wide singleton — without calling `removeTarget(_:)` on
    /// the matching command in `deinit`, every `AudioPlayer` instance that
    /// ever reaches `ensureRemoteCommands()` (any real `play()`/`resume()`
    /// call) leaks its closures onto the shared command center for the
    /// lifetime of the process. Harmless in a long-lived app (one instance),
    /// but compounds across an XCTest run that constructs dozens of real
    /// `AudioPlayer`s in one process on a physical device with a real
    /// audio session.
    nonisolated(unsafe) private var remoteCommandRemovers: [() -> Void] = []
    private var wasPlayingBeforeInterruption = false
    /// Last (bookId, chapterName, isPlaying) tuple pushed to the widget via
    /// the RELOADING `WidgetDataSync.updateNowPlaying`. `syncWidgetNowPlaying()`
    /// runs on every ~1Hz Now Playing refresh during playback, but
    /// `WidgetCenter.reloadTimelines` is a cross-process XPC call to
    /// `widgetkitd` — firing it every second (three kinds at once) queues up
    /// widgetkitd work and made the widget's own play button feel like it
    /// "trava e fica pesado" under repeated taps, because each tap's
    /// `resume()` → `updateNowPlayingInfo()` added another reload burst on
    /// top of an already-backlogged queue. Only the fields that actually
    /// changed (chapter advance, play/pause) warrant a timeline reload;
    /// bare progress ticks use `updateNowPlayingProgress` (write-only, no
    /// `reloadTimelines` call).
    private var lastSyncedWidgetState: (bookId: String, chapterName: String?, isPlaying: Bool)?

    // Segment-mode cumulative position tracking: AVQueuePlayer reports
    // per-item position, but SyncEngine needs chapter-relative time.
    private var isSegmentMode = false
    private var segmentChapterIndex: Int = -1
    private var segmentCumulativeBase: TimeInterval = 0
    private var segmentChapterDuration: TimeInterval = 0
    /// Estimates are kept per chapter. A later buffered chapter must never
    /// overwrite the audible chapter's duration while it is still playing.
    private var segmentEstimatedDurations: [Int: TimeInterval] = [:]
    /// Segment metadata is keyed by producer identity rather than arrival
    /// order. Python callbacks may cross MainActor turns; the currently
    /// playing AVPlayerItem remains the source of truth for active state.
    private var segmentSentenceIDs: [SegmentBacklog.Identity: String] = [:]
    private var segmentFiles: [SegmentBacklog.Identity: URL] = [:]
    private var activeSegmentIdentity: SegmentBacklog.Identity?
    /// AVQueuePlayer removes a finished item before it posts the end
    /// notification. Keep the identities registered at insertion time so the
    /// end handler can filter unrelated players without missing our own
    /// buffer-drain event.
    private var ownedPlayerItemIDs: Set<ObjectIdentifier> = []
    /// Producers wait here when the file-backed deferred queue reaches its
    /// bounded capacity. The continuations resume as AVQueuePlayer accepts
    /// deferred items, so conversion pauses without deleting audio or
    /// accumulating an unbounded number of temporary files.
    private var segmentCapacityWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Requested playable-list index from the last `play(snapshot:)`
    /// call that arrived before any MP3 URL existed. When the first
    /// playable snapshot lands via SSE, `updateSnapshot` uses this to
    /// build the queue at the same requested starting point instead of
    /// defaulting back to chapter 0.
    private var pendingSnapshotStartIndex: Int?
    /// Queue-order chapter list backing the currently-mounted AVQueuePlayer.
    /// `JobSnapshot.playableChapters` is sorted by EPUB index, which is right
    /// for library/TOC display but wrong for on-demand streaming when the
    /// backend starts at chapter N and later wraps to 0. This list preserves
    /// the actual append order of the live queue.
    private var playbackChapters: [JobSnapshot.Chapter] = []

    nonisolated private static let maxQueueAhead = 5
    /// Deferred file-backed segments. Entries are never evicted: they are
    /// retained until AVQueuePlayer accepts them or the session is torn down.
    /// The value type keeps ordering + empty-streak behavior
    /// unit-testable without an AVPlayer mock — see
    /// `Services/SegmentBacklog.swift`.
    private var backlog = SegmentBacklog()

    private var remoteCommandsConfigured = false

    enum InterruptionRecoveryAction: Equatable {
        case pause
        case resume
        case none
    }

    enum RouteChangeReason: Int, Equatable {
        case unknown = 0
        case newDeviceAvailable = 1
        case oldDeviceUnavailable = 2
        case categoryChange = 3
    }

    nonisolated static func interruptionRecoveryAction(
        interruptionBegan: Bool,
        shouldResume: Bool,
        wasPlaying: Bool
    ) -> InterruptionRecoveryAction {
        if interruptionBegan { return wasPlaying ? .pause : .none }
        return shouldResume && wasPlaying ? .resume : .none
    }

    nonisolated static func shouldPauseForRouteChange(reason: RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }

    nonisolated static func shouldRecoverFromMediaServicesReset(wasPlaying: Bool) -> Bool {
        wasPlaying
    }

    nonisolated static func audioSessionConfigurationStateAfterAttempt(succeeded: Bool) -> Bool {
        succeeded
    }

    nonisolated static func reconciledIsPlaying(queueRate: Float, currentIsPlaying: Bool) -> Bool {
        queueRate > 0
    }

    // MARK: Speech fallback (slice 2)

    /// Accessibility-grade speech fallback. Used only when MP3 audio is
    /// not yet ready or not playable AND the chapter text is available.
    /// The MP3 path remains primary — fallback is opt-in per chapter via
    /// `playFallbackSpeech(text:languageCode:)`.
    private let speechFallback: SpeechFallbackPlayer

    /// Separate observable seam for 250 ms transport updates. It is
    /// injected into transport subviews only; library and reader content
    /// observe the structural `AudioPlayer` without subscribing to this
    /// clock.
    let playbackClock: PlaybackClock

    /// `true` while the speech fallback owns the transport. Flips to
    /// `true` on a successful `playFallbackSpeech` and back to `false`
    /// the moment an MP3 takeover happens (`play(snapshot:)`) or the
    /// user explicitly stops playback. Drives UI controls so callers
    /// know which subsystem to drive — without this flag every play /
    /// pause tap would race the MP3 queue against the synthesizer.
    @Published private(set) var isUsingSpeechFallback: Bool = false

    init(
        resumeStore: ResumeStore = ResumeStore(),
        backendBaseURL: URL? = nil,
        speechFallback: SpeechFallbackPlayer? = nil,
        playbackClock: PlaybackClock? = nil
    ) {
        self.playbackClock = playbackClock ?? PlaybackClock()
        self.resumeStore = resumeStore
        self.backendBaseURL = backendBaseURL
        // Default-construct on MainActor (this init's isolation). A
        // non-nil default expression would be evaluated in the caller's
        // context, which the compiler cannot prove is MainActor.
        self.speechFallback = speechFallback ?? SpeechFallbackPlayer()
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
        // Explicitly tear down AVQueuePlayer resources before ARC releases
        // the object. Leaving failed/test items queued can keep AVFoundation
        // worker threads alive and prevent XCTest from terminating cleanly.
        let queuedPlayer = player
        Task { @MainActor [queuedPlayer] in
            queuedPlayer?.pause()
            queuedPlayer?.removeAllItems()
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        currentItemObserver?.invalidate()
        for token in audioSessionObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        // Undo `ensureRemoteCommands()` / `ensureAudioSession()` so this
        // instance's real system registrations don't outlive it — see
        // `releaseSystemPlaybackResources()` doc comment. `deinit` on a
        // `@MainActor` class is non-isolated under Swift 6; every property
        // this touches (`remoteCommandRemovers`, `audioSessionConfigured`)
        // is either `nonisolated(unsafe)` or, like the observer tokens
        // above, only ever mutated from MainActor call sites that have
        // already returned by the time ARC reaches zero refcount.
        releaseSystemPlaybackResources()
        // Drain AsyncStream continuations so any subscriber that holds
        // an unbroken `for await pos in player.position` loop exits
        // cleanly. Without this, a subscriber Task could hang forever
        // waiting on a stream that will never yield again — leaking
        // the Task itself and anything it captured.
        for cont in chapterContinuations.values { cont.finish() }
        for cont in positionContinuations.values { cont.finish() }
        chapterContinuations.removeAll()
        positionContinuations.removeAll()
        // The AVQueuePlayer is released immediately after this deinit
        // returns — no need to pause it. AVFoundation tears down its
        // own state when refcount hits zero.
    }

    // MARK: Remote commands (lazy — deferred to first playback)

    /// Configure the lock-screen / Control Center remote commands once.
    /// Lazy: triggered on first playback, not in `init`. Idempotent —
    /// guarded by `remoteCommandsConfigured`. Exposed (not `private`)
    /// so tests can assert command/​interval registration deterministically
    /// without a real `play()` call.
    func ensureRemoteCommands() {
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
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback, mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
            if #available(iOS 17.0, *) {
                try session.setPrefersInterruptionOnRouteDisconnect(true)
            }
            try session.setActive(true, options: [])
            audioSessionConfigured = true
            installAudioSessionObservers()
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
                audioSessionConfigured = true
                installAudioSessionObservers()
            } catch {
                audioSessionConfigured = false
            }
        }
        #endif
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        guard audioSessionObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        audioSessionObserverTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let optionRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated { [weak self] in
                self?.handleInterruption(typeRaw: typeRaw, optionRaw: optionRaw)
            }
        })
        audioSessionObserverTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue
            MainActor.assumeIsolated { [weak self] in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        })
        audioSessionObserverTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        })
        #endif
    }

    #if os(iOS)
    private func handleInterruption(typeRaw: UInt?, optionRaw: UInt) {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { player?.pause(); isPlaying = false }
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume)
            guard shouldResume, wasPlayingBeforeInterruption else { return }
            ensureAudioSession()
            player?.rate = rate.rawValue
            isPlaying = player?.rate ?? 0 > 0
            updateNowPlayingInfo()
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: Int?) {
        guard let raw = reasonRaw,
              let reason = RouteChangeReason(rawValue: raw) else { return }
        if Self.shouldPauseForRouteChange(reason: reason), isPlaying {
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    private func handleMediaServicesReset() {
        let shouldResume = isPlaying || wasPlayingBeforeInterruption
        audioSessionConfigured = false
        for token in audioSessionObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        audioSessionObserverTokens.removeAll()
        guard shouldResume else { return }
        ensureAudioSession()
        player?.rate = rate.rawValue
        isPlaying = player?.rate ?? 0 > 0
        updateNowPlayingInfo()
    }
    #endif

    // MARK: Public API

    func setSnapshot(_ snapshot: JobSnapshot) {
        self.snapshot = snapshot
        updateNowPlayingInfo()
    }

    /// Bind an active remote conversion before its first completed chapter
    /// exists. This gives progressive media chunks a stable player owner
    /// without interrupting another book that is already playing.
    @discardableResult
    func beginRemoteStreaming(snapshot incomingSnapshot: JobSnapshot, backendBaseURL: URL) -> Bool {
        let isSameJob = snapshot?.jobId == incomingSnapshot.jobId
        guard isSameJob || (player == nil && !isPlaying && !isUsingSpeechFallback) else {
            return false
        }

        if !isSameJob {
            clearConversionState()
            readerChapterTitles.removeAll()
            playbackChapters.removeAll()
            currentChapterIndex = 0
            isSegmentMode = false
            segmentCumulativeBase = 0
            segmentChapterDuration = 0
            segmentEstimatedDurations.removeAll()
            segmentChapterIndex = -1
            segmentSentenceIDs.removeAll()
            segmentFiles.removeAll()
            activeSegmentIdentity = nil
            activeSentenceId = nil
            pendingSnapshotStartIndex = 0
            pendingAutoPlay = false
            pendingSegmentResumePosition = nil
            lastError = nil
        }

        self.backendBaseURL = backendBaseURL
        self.snapshot = incomingSnapshot
        isConverting = !incomingSnapshot.isTerminal
        if let total = incomingSnapshot.chaptersTotal, total > 0 {
            conversionProgress = Double(incomingSnapshot.chaptersCompleted ?? 0) / Double(total)
        } else {
            conversionProgress = nil
        }
        updateNowPlayingInfo()
        return true
    }

    nonisolated static func segmentPosition(
        durations: [TimeInterval],
        segmentIndex: Int,
        itemPosition: TimeInterval
    ) -> TimeInterval {
        let base = durations.prefix(max(0, segmentIndex)).reduce(0) { total, duration in
            total + (duration.isFinite && duration > 0 ? duration : 0)
        }
        let position = itemPosition.isFinite ? max(0, itemPosition) : 0
        let duration = durations.indices.contains(segmentIndex) ? durations[segmentIndex] : .infinity
        return base + min(position, duration.isFinite && duration > 0 ? duration : position)
    }

    nonisolated static func segmentDuration(durations: [TimeInterval]) -> TimeInterval {
        durations.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
    }

    nonisolated static func segmentDuration(_ durations: [TimeInterval]) -> TimeInterval {
        segmentDuration(durations: durations)
    }

    nonisolated static func estimatedChapterDurationSeconds(
        wordCount: Int,
        wordsPerMinute: Double = 200
    ) -> TimeInterval {
        guard wordCount > 0, wordsPerMinute.isFinite, wordsPerMinute > 0 else { return 0 }
        return Double(wordCount) / wordsPerMinute * 60
    }

    nonisolated static func segmentChapterTitle(
        chapterIndex: Int,
        chapterProgress: [JobSnapshot.Chapter]
    ) -> String {
        let chapter = chapterProgressEntry(
            forSegmentIndex: chapterIndex,
            chapterProgress: chapterProgress
        )
        return preferredChapterTitle(
            primary: chapter?.name,
            secondary: nil,
            fallback: L10n.string("player.chapter", chapterIndex + 1)
        )
    }

    /// Server chapter indexes are one-based while some older embedded
    /// snapshots are zero-based. Detect the persisted convention instead of
    /// guessing from the playback cursor, so title and queue reconciliation
    /// identify the same chapter on both paths.
    private nonisolated static func chapterProgressEntry(
        forSegmentIndex segmentIndex: Int,
        chapterProgress: [JobSnapshot.Chapter]
    ) -> JobSnapshot.Chapter? {
        let usesZeroBasedIndexes = chapterProgress.contains { $0.index == 0 }
        let preferredIndex = usesZeroBasedIndexes ? segmentIndex : segmentIndex + 1
        let alternateIndex = usesZeroBasedIndexes ? segmentIndex + 1 : segmentIndex
        return chapterProgress.first { $0.index == preferredIndex }
            ?? chapterProgress.first { $0.index == alternateIndex }
    }

    func setSegmentChapterEstimate(_ duration: TimeInterval, forChapterIndex chapterIndex: Int) {
        guard duration.isFinite, duration > 0 else { return }
        segmentEstimatedDurations[chapterIndex] = duration
        if isSegmentMode, segmentChapterIndex == chapterIndex {
            segmentChapterDuration = max(segmentChapterDuration, duration)
            durationSeconds = segmentChapterDuration
        }
    }

    nonisolated static func segmentProgress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }

    nonisolated static func segmentRemaining(position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, duration - max(0, position.isFinite ? position : 0))
    }

    struct SegmentSeekTarget: Equatable {
        let segmentIndex: Int
        let offset: TimeInterval
    }

    nonisolated static func segmentSeekTarget(
        position: TimeInterval,
        durations: [TimeInterval]
    ) -> SegmentSeekTarget? {
        guard !durations.isEmpty else { return nil }
        let target = min(segmentDuration(durations: durations), max(0, position.isFinite ? position : 0))
        var base: TimeInterval = 0
        for (index, duration) in durations.enumerated() where duration.isFinite && duration > 0 {
            if target <= base + duration || index == durations.count - 1 {
                return SegmentSeekTarget(segmentIndex: index, offset: min(duration, max(0, target - base)))
            }
            base += duration
        }
        return nil
    }

    nonisolated static func shouldDrainSegmentBacklog(queueCount: Int, maxQueueAhead: Int) -> Bool {
        queueCount < max(1, maxQueueAhead)
    }

    nonisolated static func validatedDurationSeconds(
        _ seconds: TimeInterval,
        isReadyToPlay: Bool
    ) -> TimeInterval? {
        guard isReadyToPlay, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    nonisolated static func resumeMarkerToPersistBeforeTeardown(
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

    /// Pure index-resolution logic behind `reconcileChapterIndexFromCurrentItem()`.
    /// Extracted so it's unit-testable without a real `AVPlayerItem`/`AVQueuePlayer`.
    ///
    /// Some books produce two "chapters" (e.g. a cover-image placeholder and a
    /// near-empty title page) whose `downloadUrl`s resolve to the exact same
    /// cached/near-silent MP3. `AVQueuePlayer` (with `actionAtItemEnd = .advance`)
    /// only ever moves forward through its items — it never rewinds. Resolving
    /// a duplicate URL with a plain "first match from index 0" always snaps
    /// back to the earlier chapter, which ping-pongs the lock-screen /
    /// Now Playing title between the two every time KVO fires. Searching
    /// forward from `currentIndex` (wrapping only if nothing at/after it
    /// matches) keeps resolution monotonic with the queue's forward-only
    /// advance and eliminates the oscillation.
    ///
    /// Returns `nil` when no chapter's resolved URL matches `currentItemURL`
    /// (mirrors the "not found" case of the instance method).
    nonisolated static func resolveChapterIndex(
        currentIndex: Int,
        chapterURLs: [URL?],
        currentItemURL: URL
    ) -> Int? {
        guard chapterURLs.indices.contains(currentIndex) else { return nil }
        let searchOrder = Array(chapterURLs.indices[currentIndex...]) + Array(chapterURLs.indices[..<currentIndex])
        return searchOrder.first { i in chapterURLs[i] == currentItemURL }
    }

    /// Embedded synthesis queues files as `ch<N>-seg<M>.mp3`. This is the
    /// authoritative chapter identity while `AVQueuePlayer` advances through
    /// streamed segments, because embedded snapshots have no download URLs.
    nonisolated static func chapterIndexForSegmentItem(_ url: URL) -> Int? {
        segmentIdentityForSegmentItem(url)?.chapterIndex
    }

    /// Decode the stable producer identity from both legacy
    /// `ch<N>-seg<M>.mp3` names and collision-safe session filenames such as
    /// `stream-<uuid>-ch<N>-seg<M>-<uuid>.mp3`.
    nonisolated static func segmentIdentityForSegmentItem(_ url: URL) -> SegmentBacklog.Identity? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        for index in parts.indices.dropLast() {
            let chapterPart = parts[index]
            let segmentPart = parts[parts.index(after: index)]
            guard chapterPart.hasPrefix("ch"), segmentPart.hasPrefix("seg"),
                  let chapter = Int(chapterPart.dropFirst(2)),
                  let segment = Int(segmentPart.dropFirst(3)) else {
                continue
            }
            return SegmentBacklog.Identity(chapterIndex: chapter, segmentIndex: segment)
        }
        return nil
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
        // MP3 takeover: if the speech fallback was holding the place,
        // shut it down BEFORE we set up the AVQueuePlayer so the user
        // never hears both transports overlap (synth + MP3 = garbled).
        // No-op when fallback was idle, so this stays cheap.
        if isUsingSpeechFallback {
            speechFallback.stop()
            isUsingSpeechFallback = false
        }
        // Audio session is intentionally NOT activated here — `setActive(true)`
        // on a `.playback` / `.longFormAudio` session interrupts other apps
        // (Spotify, Apple Music, podcast apps) even when our queue is paused.
        // We defer activation to `resume()` so silence on the user's side
        // never costs them their currently-playing audio.
        audioLog.debug("[load] snapshot jobId=\(snapshot.jobId) chapterIndex=\(chapterIndex) playableChapters=\(snapshot.playableChapters.count)")
        // Touch last-access so LRU eviction knows this audiobook was opened.
        AudiobookCacheEviction.touchLastAccess(jobId: snapshot.jobId)
        // Embedded-runtime preservation: when the host already streamed
        // segments into the queue via `enqueueSegment` (the only way
        // audio reaches the player in embedded mode — chapters carry
        // no `downloadUrl`), a subsequent `play(snapshot:)` call from
        // the divergence-dialog path used to teardown the live player
        // and then refuse to rebuild (no URLs). The user saw "asks to
        // download, never plays" even though every chapter was on disk
        // and queued. Keep the live segment queue intact; the caller
        // (`startFromBeginning` / `startFromReaderPage`) will issue the
        // appropriate `seek` + `resume` after this returns.
        if isSegmentMode, player != nil, snapshot.playableChapters.isEmpty {
            self.snapshot = snapshot
            updateNowPlayingInfo()
            return
        }
        let wasPlaying = isPlaying
        if let marker = Self.resumeMarkerToPersistBeforeTeardown(
            jobId: self.snapshot?.jobId,
            chapterIndex: currentChapterIndex,
            positionSeconds: positionSeconds
        ) {
            resumeStore.save(
                jobId: marker.jobId,
                chapterIndex: marker.chapterIndex,
                position: marker.positionSeconds
            )
        }
        teardownPlayer()
        // Reset index immediately after teardown so subscribers never see
        // the old chapter index in the window before the new one is set below.
        currentChapterIndex = max(0, min(chapterIndex, snapshot.playableChapters.count - 1))
        isSegmentMode = false
        segmentCumulativeBase = 0
        segmentChapterDuration = 0
        segmentChapterIndex = -1
        activeSegmentIdentity = nil
        activeSentenceId = nil
        playbackChapters = []
        self.snapshot = snapshot

        let chapters = snapshot.playableChapters
        let requestedStartIndex = max(0, chapterIndex)
        let safeIndex = max(0, min(chapterIndex, chapters.count - 1))
        guard !chapters.isEmpty else {
            audioLog.warning("[load] no playable chapters — player not started")
            pendingSnapshotStartIndex = requestedStartIndex
            if snapshot.isTerminal {
                lastError = .noPlayableChapters
            }
            return
        }
        pendingSnapshotStartIndex = nil
        playbackChapters = chapters

        // Build the queue starting AT `safeIndex` rather than building
        // the full list and walking `advanceToNextItem()` to skip
        // forward. For a 200-chapter book jumping to chapter 150 the
        // old approach allocated 150 AVPlayerItems and fired 150 KVO
        // ticks on `currentItem` before any audio played; the slice
        // approach allocates the 50 items we actually need and is O(1).
        let remaining = chapters[safeIndex...]
        let items = remaining.compactMap { chapter -> AVPlayerItem? in
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl,
                                              jobId: snapshot.jobId,
                                              chapterIndex: chapter.index) else { return nil }
            return AVPlayerItem(url: absolute)
        }
        guard !items.isEmpty else { return }

        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        self.player = queue
        ownedPlayerItemIDs = Set(items.map { ObjectIdentifier($0) })
        self.currentChapterIndex = safeIndex

        attachObservers()

        // Restore prior position for this chapter, if any.
        let resumeMarker = resumeStore.marker(jobId: snapshot.jobId, chapterIndex: safeIndex)
        if let marker = resumeMarker,
           marker.positionSeconds > 1.0 {
            queue.seek(to: CMTime(seconds: marker.positionSeconds, preferredTimescale: 600))
        }

        // Queue is paused at rate 0 (default). Lock-screen / widget / in-app
        // play controls call `resume()` to start playback.
        queue.rate = 0
        isPlaying = false
        // If the previous snapshot was already playing (e.g. user jumped to a
        // new chapter while listening), or the user tapped Play while waiting
        // for the first streamed MP3 URL, preserve that intent.
        if wasPlaying || pendingAutoPlay || (resumeMarker?.wasPlaying == true) {
            queue.rate = rate.rawValue
            isPlaying = true
            pendingAutoPlay = false
        }
        // Re-register for remote-control events so the lock-screen play
        // button works even when we never auto-started. Idempotent.
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        publishCurrentChapter()
        updateNowPlayingInfo()
    }

    /// Live-update the snapshot. Used by the native reader's SSE
    /// subscription so newly-finished chapters can be appended to the
    /// AVQueuePlayer without interrupting the chapter currently playing.
    ///
    /// Two kinds of change are applied:
    ///  - **Append** newly-finished chapters at the tail (the common case).
    ///  - **Replace** an already-queued chapter whose `downloadUrl` changed
    ///    (a re-synthesis / retry that produced a new file at the same index).
    ///    Only chapters strictly ahead of the one currently playing are
    ///    swapped, so the playhead is never disturbed.
    func updateSnapshot(_ newSnapshot: JobSnapshot) {
        guard let queue = player else {
            // No player yet. If this is the first SSE snapshot that
            // carries playable MP3s, build the queue now; otherwise the
            // reader stays stuck in "converting" until the user exits and
            // reopens. Playback still does not auto-start unless a prior
            // user intent armed `pendingAutoPlay`.
            self.snapshot = newSnapshot
            if !newSnapshot.playableChapters.isEmpty {
                let startIndex = pendingSnapshotStartIndex ?? currentChapterIndex
                play(snapshot: newSnapshot, startingAt: startIndex)
            }
            return
        }

        // Segment streaming owns the live queue until the conversion reaches
        // its terminal snapshot. Appending a newly-complete chapter MP3 here
        // would replay audio that has already been queued segment-by-segment.
        // `finishStreaming(snapshot:)` performs the one deliberate handoff
        // to canonical chapter files once all segments are complete.
        if isSegmentMode {
            self.snapshot = newSnapshot
            updateNowPlayingInfo()
            return
        }

        let oldChapters = playbackChapters.isEmpty ? (self.snapshot?.playableChapters ?? []) : playbackChapters
        let newChapters = newSnapshot.playableChapters
        self.snapshot = newSnapshot

        // Replace future chapters whose file URL changed (re-synthesis). The
        // decision is pure so it can be unit-tested; applying it walks the
        // live queue to find the item to swap without touching the playhead.
        let canSafelySwapByPosition = oldChapters.indices.allSatisfy { idx in
            idx < newChapters.count && oldChapters[idx].index == newChapters[idx].index
        }
        if canSafelySwapByPosition {
            let indicesToReplace = Self.chapterIndicesNeedingURLSwap(
                old: oldChapters,
                new: newChapters,
                currentlyPlayingIndex: currentChapterIndex
            )
            for chapterIdx in indicesToReplace {
                replaceQueuedItem(atChapterIndex: chapterIdx, in: queue, chapters: newChapters)
            }
        }

        // Append every chapter whose EPUB index was not already queued.
        // Count-based suffix appends break when on-demand streaming starts
        // in the middle of a book and later wraps to earlier EPUB indices:
        // sorted playableChapters become [0, 10, 11] after [10, 11], so
        // `suffix(1)` would duplicate 11 and drop 0. Identity-based diffing
        // preserves the live queue while accepting out-of-order arrivals.
        let chaptersToAppend = Self.chaptersToAppend(old: oldChapters, new: newChapters)
        for chapter in chaptersToAppend {
            guard let absolute = absoluteURL(forDownloadPath: chapter.downloadUrl,
                                              jobId: newSnapshot.jobId,
                                              chapterIndex: chapter.index) else { continue }
            let item = AVPlayerItem(url: absolute)
            if queue.canInsert(item, after: nil) {
                queue.insert(item, after: nil)
                ownedPlayerItemIDs.insert(ObjectIdentifier(item))
                playbackChapters.append(chapter)
            }
        }
        updateNowPlayingInfo()
    }

    /// Publish a completed manifest for a segment-streaming session without
    /// leaving playback tied to temporary MP3 files. The final chapter URLs
    /// restore standard seeking, resume, and offline playback.
    func finishStreaming(snapshot: JobSnapshot) {
        guard isSegmentMode, player != nil else {
            isConverting = false
            updateSnapshot(snapshot)
            return
        }
        let activeChapterID = Self.chapterProgressEntry(
            forSegmentIndex: currentChapterIndex,
            chapterProgress: snapshot.chapterProgress ?? []
        )?.index
        // `positionSeconds` is chapter-relative in segment mode. The periodic
        // observer has already added `segmentCumulativeBase`, so subtracting
        // it here rewound the full-file handoff to an earlier segment.
        let activePosition = max(0, positionSeconds)
        let wasPlaying = isPlaying
        let target = activeChapterID.flatMap { chapterID in
            snapshot.playableChapters.firstIndex { $0.index == chapterID }
        } ?? 0
        isConverting = false
        // Once every full chapter file exists, replace the segment queue with
        // the canonical chapter queue. This restores normal previous/next,
        // seeking, resume markers, and offline playback semantics without
        // leaving the player permanently tied to per-segment items.
        play(snapshot: snapshot, startingAt: target)
        if activePosition > 0 { seek(to: activePosition) }
        if wasPlaying { resume() }
    }

    /// Compatibility spelling for existing embedded-runtime callers.
    func finishEmbeddedStreaming(snapshot: JobSnapshot) {
        finishStreaming(snapshot: snapshot)
    }

    /// Chapters present in `new` but absent from `old`, keyed by the EPUB-side
    /// chapter index. Pure helper for streaming updates where completion order
    /// can differ from EPUB order because the backend prioritises the chapter
    /// the user is reading first, then wraps around.
    nonisolated static func chaptersToAppend(
        old: [JobSnapshot.Chapter],
        new: [JobSnapshot.Chapter]
    ) -> [JobSnapshot.Chapter] {
        let existing = Set(old.map(\.index))
        return new.filter { !existing.contains($0.index) }
    }

    /// Which `playableChapters` indices changed their `downloadUrl` and are
    /// safe to swap in the queue. A chapter qualifies when it existed in the
    /// old snapshot, its non-nil URL differs in the new snapshot, and it is
    /// strictly ahead of the chapter currently playing (so the live item is
    /// never yanked out from under the playhead). Pure + static + nonisolated
    /// so it is callable from a synchronous test context (AudioPlayer is
    /// @MainActor; this function touches no instance state).
    nonisolated static func chapterIndicesNeedingURLSwap(
        old: [JobSnapshot.Chapter],
        new: [JobSnapshot.Chapter],
        currentlyPlayingIndex: Int
    ) -> [Int] {
        var result: [Int] = []
        let shared = min(old.count, new.count)
        var idx = currentlyPlayingIndex + 1
        while idx < shared {
            let newURL = new[idx].downloadUrl
            if let newURL, !newURL.isEmpty, newURL != old[idx].downloadUrl {
                result.append(idx)
            }
            idx += 1
        }
        return result
    }

    /// Swap the queued AVPlayerItem for `chapterIndex` (an index into
    /// `playableChapters`) with a fresh item built from its current URL.
    /// The queue holds items from `currentChapterIndex` onward, so the queue
    /// offset is `chapterIndex - currentChapterIndex`. No-ops defensively if
    /// the offset, URL, or AVQueuePlayer insertion constraints don't line up —
    /// the item is simply left as-is rather than risking a playhead glitch.
    private func replaceQueuedItem(
        atChapterIndex chapterIndex: Int,
        in queue: AVQueuePlayer,
        chapters: [JobSnapshot.Chapter]
    ) {
        let queueOffset = chapterIndex - currentChapterIndex
        let items = queue.items()
        guard queueOffset > 0, queueOffset < items.count else { return }
        guard chapterIndex < chapters.count,
              let absolute = absoluteURL(forDownloadPath: chapters[chapterIndex].downloadUrl,
                                          jobId: snapshot?.jobId,
                                          chapterIndex: chapters[chapterIndex].index) else { return }
        let stale = items[queueOffset]
        let anchor = items[queueOffset - 1]
        let fresh = AVPlayerItem(url: absolute)
        queue.remove(stale)
        ownedPlayerItemIDs.remove(ObjectIdentifier(stale))
        if queue.canInsert(fresh, after: anchor) {
            queue.insert(fresh, after: anchor)
            ownedPlayerItemIDs.insert(ObjectIdentifier(fresh))
        }
    }

    func pause() {
        // Slice-2 speech-fallback route: when the synthesizer owns the
        // transport, pause/resume must drive it instead of the silent
        // AVQueuePlayer. We do NOT touch the MP3 player here — it stays
        // torn down until an MP3 takeover (`play(snapshot:)`) happens.
        if isUsingSpeechFallback {
            speechFallback.pause()
            isPlaying = false
            return
        }
        player?.pause()
        isPlaying = false
        persistResumePoint(force: true)
        updateNowPlayingInfo()
    }

    func resume() {
        if isUsingSpeechFallback {
            // Speech fallback already configured the audio session for
            // `.spokenAudio` when `playFallbackSpeech` ran — no extra
            // session work here. Resume just continues the utterance.
            speechFallback.resume()
            isPlaying = true
            return
        }
        guard let player else {
            pendingAutoPlay = true
            if let snapshot, !snapshot.playableChapters.isEmpty {
                play(snapshot: snapshot, startingAt: currentChapterIndex)
            }
            return
        }
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

    /// True only after an AV queue exists. A snapshot may arrive before its
    /// first audio segment, so snapshot presence alone is not enough to make
    /// a Play tap audible.
    var hasLoadedAudioQueue: Bool { player != nil }

    // MARK: - Speech fallback (slice 2)

    /// True when the host should drive the speech-fallback path instead
    /// of the MP3 path for the given chapter. The MP3 path is preferred
    /// — fallback only fires when no snapshot exists, the snapshot
    /// carries no playable chapters, or the chapter at the requested
    /// index has no `downloadUrl` yet.
    ///
    /// Pure decision helper — does not mutate state. Callers combine
    /// this with chapter-text availability (only the reader/view layer
    /// knows about `EbookFulltext`) before invoking `playFallbackSpeech`.
    func shouldUseSpeechFallback(for snapshot: JobSnapshot?, chapterIndex: Int) -> Bool {
        guard let snapshot else { return true }
        let playable = snapshot.playableChapters
        if playable.isEmpty { return true }
        // Requested index lives in the EPUB-zero-based space (same key
        // `chapter.index` uses in the snapshot). If the snapshot lacks
        // an entry for it, MP3 is not ready for THIS chapter even if
        // earlier/later ones are.
        return !playable.contains { $0.index == chapterIndex }
    }

    /// Engage the accessibility speech fallback for the given chapter
    /// text. `text` must be non-empty — empty input is treated as a
    /// no-op so the fallback flag never silently flips on a degenerate
    /// call. Configures the system audio session for `.spokenAudio`
    /// (via `SpeechFallbackPlayer`) and surfaces `isPlaying = true`
    /// so the existing transport UI (play/pause button, mini-player)
    /// reflects the correct state without further wiring.
    ///
    /// The MP3 path is NOT primed — callers that already loaded a
    /// snapshot keep it; calling `play(snapshot:)` later cleanly
    /// switches back to MP3 and stops the synthesizer in the same turn
    /// so the user never hears both transports.
    func playFallbackSpeech(text: String, languageCode: String? = nil) {
        guard !text.isEmpty else { return }
        speechFallback.speak(text: text, languageCode: languageCode)
        isUsingSpeechFallback = true
        isPlaying = true
    }

    /// Outcome of `playOrFallback`. Returned synchronously so UI surfaces
    /// can decide whether to update a "now playing" banner, surface a
    /// "still converting" hint, or stay silent. `Equatable` so tests can
    /// pin the result; the discriminant is enough — no associated data
    /// needed today.
    enum PlaybackAttemptResult: Equatable {
        case startedAudio
        case startedSpeechFallback
        case noOp
    }

    /// Unified play entry the reader/UI surfaces call when the user taps
    /// Play. Resolves the route once so callers don't have to duplicate
    /// the "is MP3 ready? else can we speak? else do nothing" tree at
    /// every button site.
    ///
    /// Decision order — MP3 is ALWAYS primary:
    /// 1. The requested EPUB chapter has a playable `downloadUrl` in the
    ///    snapshot ⇒ `.startedAudio` (existing `play(snapshot:startingAt:)`
    ///    path, including the MP3-takeover stop of any active fallback).
    /// 2. The snapshot lacks a playable URL for the requested chapter
    ///    AND `chapterText` has non-whitespace content ⇒
    ///    `.startedSpeechFallback` (accessibility synth).
    /// 3. Neither ⇒ `.noOp` — no transport state mutates, no flag flips,
    ///    no UI flicker.
    ///
    /// `chapterIndex` is the EPUB-zero-based index (same space the reader
    /// publishes into UserDefaults). Translation to
    /// the playable-list index used by `play(snapshot:startingAt:)` is
    /// done here so call sites never need both numbers.
    @discardableResult
    func playOrFallback(
        snapshot: JobSnapshot?,
        chapterIndex: Int,
        chapterText: String?,
        languageCode: String? = nil
    ) -> PlaybackAttemptResult {
        if let snapshot,
           let playableIdx = snapshot.playableChapters
            .firstIndex(where: { $0.index == chapterIndex }) {
            play(snapshot: snapshot, startingAt: playableIdx)
            return .startedAudio
        }

        let trimmed = (chapterText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noOp }
        playFallbackSpeech(text: trimmed, languageCode: languageCode)
        return .startedSpeechFallback
    }

    // MARK: Play-tap routing (centralised so every UI surface — mini
    // player, full player, in-line buttons in the reader — uses the
    // same divergence detection / start-options behaviour. Adding a new
    // play button anywhere in the app should only require wiring
    // `playTapDecision(readerChapterIndex:readerPageRatio:)` + `startFromReaderPage(_:)`
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
        /// Reader sits on a different chapter/page than the audio. The UI
        /// surface should show the start-position chooser
        /// (current page / where stopped).
        case offerStartChoice
    }

    func playTapDecision(
        readerChapterIndex: Int,
        readerPageRatio: Double? = nil
    ) -> PlayTapDecision {
        if isPlaying { return .pause }
        guard let snapshot else { return .resume }
        // Embedded-runtime path: chapters are fed through `enqueueSegment`
        // and the snapshot carries no `downloadUrl`s, so
        // `playableChapters` is permanently empty even though a live
        // AVQueuePlayer is loaded with audio. Without this short-circuit
        // every play tap returned `.offerStartChoice`; picking any
        // option then called `play(snapshot:)` which teardown the live
        // queue and refused to rebuild it (no URLs to build from) —
        // visible to the user as "asks to download but never plays".
        // When we're in segment mode with a live player, the divergence
        // dialog has nothing to resolve: just resume the existing queue.
        if isSegmentMode, player != nil { return .resume }
        // `readerChapterIndex` is the EPUB-zero-based chapter index
        // (the same space `fulltext.chapters[i].index - 1` lives in).
        // `currentChapterIndex` is an index into `playableChapters` —
        // the filtered subset. Compare in the *playable* space so
        // unplayable chapters between user and player (footnotes,
        // image-only sections) don't spuriously fire the dialog.
        //
        // When the reader sits BEFORE any playable chapter (e.g. the
        // book starts with a non-narratable preface and `playable[0]`
        // is EPUB index 5 while reader is at EPUB 0), there's no
        // matching playable for the reader — translation returns nil.
        // Treat that as divergent so the user gets the dialog instead
        // of a silent no-op.
        let reader = playableIndex(forEpubZeroBased: readerChapterIndex, in: snapshot)
        guard let reader else { return .offerStartChoice }
        // Once the reader and audio refer to the same chapter, Play resumes
        // that chapter directly. Page/scroll position is not a second
        // playback target: showing the chooser here made Play unexpectedly
        // offer "current page" versus "where stopped" even though the user
        // was already on the active chapter. The chooser is reserved for a
        // genuinely different chapter.
        if reader == currentChapterIndex { return .resume }
        return .offerStartChoice
    }

    /// Convert an EPUB zero-based chapter index (what the reader views
    /// publish into UserDefaults) to the matching playable-list index
    /// (what `currentChapterIndex` lives in). Returns `nil` when no
    /// playable chapter is at or before `epubIndex` (the user is
    /// reading a preface that has no audio counterpart).
    ///
    /// Otherwise falls back to the last playable chapter whose EPUB
    /// index is ≤ the reader's, so a play tap from an unplayable
    /// chapter starts from the previous playable.
    private func playableIndex(
        forEpubZeroBased epubIndex: Int,
        in snapshot: JobSnapshot
    ) -> Int? {
        let playable = snapshot.playableChapters
        guard !playable.isEmpty else { return nil }
        if let exact = playable.firstIndex(where: { $0.index == epubIndex }) {
            return exact
        }
        var fallback: Int?
        for (i, ch) in playable.enumerated() where ch.index <= epubIndex {
            fallback = i
        }
        return fallback
    }

    /// Per-chapter sentence-id → audio-ms timing maps. Populated by the
    /// `SentenceSyncEngine` host when the native reader loads a
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
        sentenceOffsetRatio: Double? = nil,
        sentenceWordOffsetRatio: Double? = nil
    ) {
        guard let snapshot else { resume(); return }
        // `readerChapterIndex` is EPUB-zero-based (reader space).
        // Translate to playable-list space — same fallback logic as
        // `playTapDecision`. Reader sitting before any playable
        // chapter (e.g. on an unplayable preface) ⇒ jump to the first
        // playable so audio actually starts somewhere coherent.
        let target = playableIndex(forEpubZeroBased: readerChapterIndex, in: snapshot) ?? 0
        play(snapshot: snapshot, startingAt: target)

        // Priority 1: sentence-level seek (precise).
        if let sentenceId,
           let map = sentenceTimingByChapter[target],
           let startMs = map[sentenceId] {
            let nextStartMs = map.values
                .filter { $0 > startMs }
                .min()
            let adjustedStartMs = Self.sentenceStartMs(
                startMs: startMs,
                nextStartMs: nextStartMs,
                offsetRatio: sentenceWordOffsetRatio ?? 0
            )
            seek(to: adjustedStartMs / 1000.0)
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
                // Bind the pending seek to the chapter we just loaded.
                // The time observer will only apply it when the player
                // is still on that exact chapter — protecting against
                // an auto-advance racing the duration publish.
                pendingProportionalSeek = .init(ratio: ratio, forChapterIndex: target)
            }
            resume()
            return
        }

        seek(to: 0)
        pendingProportionalSeek = nil
        resume()
    }

    nonisolated static func sentenceStartMs(
        startMs: Int,
        nextStartMs: Int?,
        offsetRatio: Double
    ) -> Double {
        let ratio = min(1, max(0, offsetRatio.isFinite ? offsetRatio : 0))
        let endMs = max(startMs, nextStartMs ?? startMs)
        return Double(startMs) + Double(endMs - startMs) * ratio
    }

    /// Pending fractional-position seek waiting for `durationSeconds`.
    /// to be published by the asset prepare. Tagged with the chapter
    /// index it was queued for so the time observer doesn't apply it
    /// against an unrelated chapter on auto-advance.
    private struct PendingProportionalSeek {
        let ratio: Double
        let forChapterIndex: Int
    }
    private var pendingProportionalSeek: PendingProportionalSeek?

    /// Called from the periodic time observer when `durationSeconds`
    /// transitions to a positive value. Applies only when the player
    /// is still on the chapter the seek was queued for; otherwise the
    /// pending seek is dropped (the queue advanced past it).
    func applyPendingProportionalSeek() {
        guard let pending = pendingProportionalSeek, durationSeconds > 0 else { return }
        guard pending.forChapterIndex == currentChapterIndex else {
            // Auto-advance happened between queuing and the duration
            // landing — drop the stale seek rather than applying it
            // to the wrong chapter.
            pendingProportionalSeek = nil
            return
        }
        seek(to: max(0, min(1, pending.ratio)) * durationSeconds)
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
        let target = max(0, seconds)
        if Self.shouldAdvanceAtSeekEnd(position: target, duration: durationSeconds) {
            let chapterBefore = currentChapterIndex
            if isSegmentMode {
                nextChapter()
            } else if let player {
                player.seek(to: CMTime(seconds: player.currentItem?.duration.seconds ?? target, preferredTimescale: 600))
                player.advanceToNextItem()
                _ = reconcileChapterIndexFromCurrentItem()
                if currentChapterIndex == chapterBefore {
                    player.pause()
                    isPlaying = false
                }
            }
            if currentChapterIndex != chapterBefore {
                positionSeconds = 0
            }
            broadcastPosition()
            updateNowPlayingInfo()
            return
        }
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        positionSeconds = target
        broadcastPosition()
        updateNowPlayingInfo()
    }

    func nextChapter() {
        guard let player else { return }
        if isSegmentMode {
            // Segment-mode: the queue holds many AVPlayerItems per
            // chapter. `advanceToNextItem()` moves one *segment*
            // forward; walk it until the underlying URL's chapter
            // tag changes. Items are written as "ch<N>-seg<M>.mp3"
            // by `enqueueSegment` so the chapter index is in the
            // filename. Capped at the items remaining so we never
            // spin forever.
            let startChapter = currentChapterIndex
            var safety = player.items().count
            while safety > 0 {
                player.advanceToNextItem()
                safety -= 1
                if let asset = player.currentItem?.asset as? AVURLAsset,
                   let identity = Self.segmentIdentityForSegmentItem(asset.url),
                   identity.chapterIndex != startChapter {
                    _ = activateSegmentIdentity(identity)
                    positionSeconds = 0
                    publishCurrentChapter(auto: false)
                    updateNowPlayingInfo()
                    return
                }
            }
            // No further chapter in the queue — leave the player
            // wherever advancing landed it.
            updateNowPlayingInfo()
            return
        }
        if let snapshot {
            let chapters = playbackChapters.isEmpty ? snapshot.playableChapters : playbackChapters
            guard currentChapterIndex + 1 < chapters.count else { return }
        }
        let indexBefore = currentChapterIndex
        player.advanceToNextItem()
        // Reconcile via URL first — KVO may already have advanced the index
        // on fast devices; falling back to +1 only when nothing changed.
        let _ = reconcileChapterIndexFromCurrentItem()
        if currentChapterIndex == indexBefore {
            currentChapterIndex += 1
        }
        positionSeconds = 0
        publishCurrentChapter()
        updateNowPlayingInfo()
    }

    func previousChapter() {
        if ProcessInfo.processInfo.arguments.contains("-readerNavigationDebug") {
            print("NAV previousChapter current=\(currentChapterIndex) position=\(positionSeconds) segmentMode=\(isSegmentMode)")
        }
        // Segment-mode: AVQueuePlayer can't rewind across items, so
        // "previous chapter" must rebuild the queue. When the host has
        // wired `restartSegmentQueueHandler` (the reader's embedded
        // path), delegate to it. Otherwise fall back to seek-to-0 of
        // the current item so the tap is at least visible.
        if isSegmentMode {
            if positionSeconds - segmentCumulativeBase > 3 {
                seek(to: 0)
                return
            }
            if let handler = restartSegmentQueueHandler, currentChapterIndex > 0 {
                handler(currentChapterIndex - 1)
                return
            }
            seek(to: 0)
            return
        }
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

    /// Adopt the AVQueuePlayer item that is actually audible. Buffered
    /// producer activity must never call this method: only queue creation,
    /// KVO, or an explicit queue advance are allowed to change the visible
    /// chapter cursor and sentence state.
    @discardableResult
    private func activateSegmentIdentity(_ identity: SegmentBacklog.Identity) -> Bool {
        let chapterChanged = segmentChapterIndex != identity.chapterIndex
        if chapterChanged {
            segmentChapterIndex = identity.chapterIndex
            segmentCumulativeBase = 0
            segmentChapterDuration = 0
            durationSeconds = max(0, segmentEstimatedDurations[identity.chapterIndex] ?? 0)
            activeSentenceId = nil
        }
        activeSegmentIdentity = identity
        currentChapterIndex = identity.chapterIndex
        activeSentenceId = segmentSentenceIDs[identity]
        return chapterChanged
    }

    @discardableResult
    private func activateCurrentSegmentItem() -> Bool {
        guard let player,
              let asset = player.currentItem?.asset as? AVURLAsset,
              let identity = Self.segmentIdentityForSegmentItem(asset.url) else {
            return false
        }
        return activateSegmentIdentity(identity)
    }

    /// Host-supplied callback that rebuilds the segment queue starting
    /// at the requested chapter. Wired by the native reader so
    /// `previousChapter()` and "From beginning" can leave segment mode
    /// and re-enter via the cache. Optional: when nil, segment-mode
    /// rewinds fall back to seek-to-0 of the current item.
    var restartSegmentQueueHandler: ((Int) -> Void)? = nil

    func setRate(_ rate: PlaybackRate) {
        self.rate = rate
        if let player, isPlaying { player.rate = rate.rawValue }
        updateNowPlayingInfo()
    }

    nonisolated static func shouldAdvanceAtSeekEnd(
        position: TimeInterval,
        duration: TimeInterval,
        tolerance: TimeInterval = 0.75
    ) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return position >= max(0, duration - tolerance)
    }

    nonisolated static func rateAdjustedDuration(
        seconds: TimeInterval,
        rate: PlaybackRate
    ) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds / TimeInterval(rate.rawValue)
    }

    var playbackDurationSeconds: TimeInterval {
        Self.rateAdjustedDuration(seconds: durationSeconds, rate: rate)
    }

    var playbackPositionSeconds: TimeInterval {
        Self.rateAdjustedDuration(seconds: positionSeconds, rate: rate)
    }

    /// Skip relative to the current playhead. Negative values rewind,
    /// positive fast-forward. Clamped to the current AVPlayerItem's
    /// duration.
    ///
    /// Segment-mode note: `positionSeconds` is **cumulative across all
    /// segments of the current chapter** (segmentCumulativeBase +
    /// item-relative time), but `AVPlayer.seek` always lands within
    /// the current item. Doing the math against the cumulative value
    /// silently jumped to an out-of-range CMTime and AVPlayer ignored
    /// the seek — visible as "+/-15 s buttons do nothing". Compute the
    /// delta against the current item's own clock instead.
    func skip(by deltaSeconds: TimeInterval) {
        guard let player else { return }
        let rawTime = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : 0
        let cap = durationSeconds.isFinite && durationSeconds > 0
            ? durationSeconds
            : .infinity
        let target = max(0, min(cap, rawTime + deltaSeconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        positionSeconds = isSegmentMode
            ? segmentCumulativeBase + target
            : target
        broadcastPosition()
        updateNowPlayingInfo()
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
    /// 1. Writes `data` to a collision-safe temp file so `AVPlayerItem` can
    ///    reference a stable URL (AVFoundation requires file-backed URLs
    ///    for local MP3; it does not accept in-memory `Data`).
    /// 2. Creates an `AVPlayerItem` and inserts it at the end of the queue.
    /// 3. If this is the first segment ever, creates a paused queue and sets
    ///    `firstSegmentReady = true`. It starts only after explicit user
    ///    playback intent has been recorded.
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
            // Edge-TTS occasionally emits a zero-byte preamble as the
            // first chunk; that's a normal warmup hiccup, not a user-
            // actionable error. Only surface after N consecutive
            // empties in the same chapter so the alert reflects a
            // real problem (engine misconfigured / network flap), not
            // routine ramp-up.
            if backlog.recordEmpty() {
                lastError = .emptySegmentData
            }
            return
        }
        backlog.resetEmptyStreak()

        let identity = SegmentBacklog.Identity(
            chapterIndex: chapterIndex,
            segmentIndex: segmentIndex
        )
        // Retried callbacks must not overwrite a URL that AVFoundation may
        // already be reading, nor enqueue a spoken passage twice.
        guard segmentFiles[identity] == nil else {
            audioLog.notice("[enqueueSegment] duplicate ignored ch=\(chapterIndex) seg=\(segmentIndex)")
            return
        }

        // Ensure a temp directory exists for this session. Bail
        // explicitly when createDirectory fails — without this, every
        // subsequent `data.write` would fail and we'd publish
        // `lastError = .segmentWriteFailed` on every chunk.
        if segmentTempDir == nil {
            let candidate = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("epub2mp3-segments-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(
                    at: candidate, withIntermediateDirectories: true
                )
                segmentTempDir = candidate
            } catch {
                audioLog.error("[enqueueSegment] failed to create temp dir: \(error.localizedDescription)")
                lastError = .segmentWriteFailed
                return
            }
        }
        guard let tmpDir = segmentTempDir else { return }

        // Segment indexes reset for every chapter and a conversion can be
        // restarted before an old AVURLAsset has released its file handle.
        // The session directory plus a per-write UUID prevents an incoming
        // retry or another stream from replacing an item already queued.
        let segFile = tmpDir.appendingPathComponent(
            "stream-\(UUID().uuidString)-ch\(chapterIndex)-seg\(segmentIndex)-\(UUID().uuidString).mp3"
        )
        do {
            try data.write(to: segFile)
        } catch {
            // Non-fatal: segment is lost but subsequent ones still
            // arrive. Surface so the host can warn the user if disk
            // is full — repeated emptySegmentData / segmentWriteFailed
            // toasts mean conversion will degrade further.
            audioLog.error("[enqueueSegment] write failed: \(error.localizedDescription)")
            lastError = .segmentWriteFailed
            return
        }

        isSegmentMode = true
        segmentFiles[identity] = segFile
        if let sentenceId {
            segmentSentenceIDs[identity] = sentenceId
        }

        if player == nil {
            let item = AVPlayerItem(url: segFile)
            let queue = AVQueuePlayer(items: [item])
            queue.actionAtItemEnd = .advance
            self.player = queue
            ownedPlayerItemIDs = [ObjectIdentifier(item)]
            _ = activateSegmentIdentity(identity)
            if let resume = pendingSegmentResumePosition, resume > 0 {
                queue.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                positionSeconds = resume
                pendingSegmentResumePosition = nil
            }
            attachObservers()
            // Only auto-start the first segment if the user had already
            // expressed intent to play (e.g. tapped Play while waiting for
            // the conversion to produce the first chunk, or asked for
            // "From the beginning" / "Previous chapter" which arms
            // `pendingAutoPlay` via `prepareSegmentRestart`). Otherwise
            // we set everything up but stay paused — the next user tap
            // on Play / lock-screen / widget will call `resume()`.
            if isPlaying || pendingAutoPlay {
                ensureAudioSession()
                queue.rate = rate.rawValue
                isPlaying = true
                pendingAutoPlay = false
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
            let accepted = backlog.append(
                url: segFile,
                chapterIndex: chapterIndex,
                segmentIndex: segmentIndex,
                sentenceId: sentenceId
            )
            guard accepted else {
                segmentFiles.removeValue(forKey: identity)
                segmentSentenceIDs.removeValue(forKey: identity)
                try? FileManager.default.removeItem(at: segFile)
                audioLog.notice("[enqueueSegment] duplicate backlog entry ignored ch=\(chapterIndex) seg=\(segmentIndex)")
                return
            }
            if backlog.count == SegmentBacklog.advisoryHighWaterMark {
                audioLog.notice("[enqueueSegment] deferred audio reached \(SegmentBacklog.advisoryHighWaterMark) segments; preserving file-backed backlog until playback drains it")
                conversionStatus.record(
                    .info,
                    "Playback is buffering ahead; audio remains queued until it can play."
                )
            }
            drainPendingSegments()
            audioLog.debug("[enqueueSegment] deferred ch=\(chapterIndex) seg=\(segmentIndex), pending=\(self.backlog.count), queue=\(queue.items().count)")
        }

        if !firstSegmentReady {
            firstSegmentReady = true
            // Also raise firstChapterReady so the mini-player shows play/pause.
            firstChapterReady = true
        }
        conversionStatus.record(.chunkComplete,
            "ch\(chapterIndex) segment \(segmentIndex) ready (\(data.count) bytes)")
    }

    private func drainPendingSegments() {
        guard let queue = player, !backlog.isEmpty else { return }
        while Self.shouldDrainSegmentBacklog(
            queueCount: queue.items().count,
            maxQueueAhead: Self.maxQueueAhead
        ), let next = backlog.peekNext() {
            let item = AVPlayerItem(url: next.url)
            if queue.canInsert(item, after: nil) {
                _ = backlog.drainNext()
                queue.insert(item, after: nil)
                ownedPlayerItemIDs.insert(ObjectIdentifier(item))
                audioLog.debug("[drainPending] enqueued ch=\(next.chapterIndex) seg=\(next.segmentIndex), queue=\(queue.items().count) pending=\(self.backlog.count)")
            } else {
                // Leave the entry at the front for the next item-end/KVO
                // opportunity. Never consume a segment before insertion.
                break
            }
        }
        resumeSegmentCapacityWaitersIfPossible()
    }

    /// Wait until another segment can be accepted without allowing the
    /// deferred file queue to grow without bound. The embedded conversion
    /// bridge calls this before it writes a new temporary MP3.
    func waitForSegmentCapacity() async -> Bool {
        guard backlog.count >= SegmentBacklog.maximumDeferredSegmentCount else {
            return true
        }
        return await withCheckedContinuation { continuation in
            segmentCapacityWaiters.append(continuation)
        }
    }

    private func resumeSegmentCapacityWaitersIfPossible() {
        while backlog.count < SegmentBacklog.maximumDeferredSegmentCount,
              !segmentCapacityWaiters.isEmpty {
            segmentCapacityWaiters.removeFirst().resume(returning: true)
        }
    }

    private func cancelSegmentCapacityWaiters() {
        let waiters = segmentCapacityWaiters
        segmentCapacityWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }

    /// Called by the native reader when the first
    /// playable chapter MP3 lands. Sets `firstChapterReady = true` and
    /// clears `isConverting` only if the snapshot is already terminal
    /// (all chapters done). Idempotent — safe to call multiple times.
    func markFirstChapterReady() {
        firstChapterReady = true
        conversionStatus.record(.chapterComplete, "First chapter audio ready")
    }

    /// Record a conversion error in the status log. Called by
    /// the native reader when a chapter synthesis fails so the user can
    /// see the error in `ConversionStatusSheet` and tap Retry.
    func recordConversionError(_ message: String) {
        conversionStatus.record(.error, message)
    }

    /// Live conversion event log. Populated by `enqueueSegment`,
    /// `markFirstChapterReady`, and error paths in the native reader.
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
        // Speech-fallback teardown: when the synthesizer owns playback,
        // stop it and clear the flag BEFORE the MP3 teardown so a
        // subsequent `play(snapshot:)` tap drives the primary path
        // without first having to dismiss a phantom fallback transport.
        if isUsingSpeechFallback {
            speechFallback.stop()
            isUsingSpeechFallback = false
        }
        teardownPlayer()
        isPlaying = false
        snapshot = nil
        playbackChapters = []
        currentChapterIndex = 0
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
        let cases = PlaybackRate.primaryRates
        guard let idx = cases.firstIndex(of: rate) else {
            setRate(.x100)
            return
        }
        let next = cases[(idx + 1) % cases.count]
        setRate(next)
    }

    /// Skip forward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipForward(seconds: Double? = nil) {
        skip(by: seconds ?? Self.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))
    }

    /// Skip backward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipBackward(seconds: Double? = nil) {
        let seconds = seconds ?? Self.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey)
        guard seconds > 0, positionSeconds <= seconds else {
            skip(by: -seconds)
            return
        }
        rewindToCurrentChapterStart()
    }

    private static func configuredSkipInterval(forKey key: String) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double
        return AppSettings.playbackSkipIntervals.contains(value ?? 15) ? (value ?? 15) : 15
    }

    /// Refreshes Control Center and Lock Screen intervals after a Settings change.
    func refreshRemoteSkipIntervals() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey))]
    }

    private func rewindToCurrentChapterStart() {
        guard let queue = player else { return }
        if isSegmentMode {
            let items = queue.items()
            guard let firstIndex = items.firstIndex(where: { item in
                guard let asset = item.asset as? AVURLAsset else { return false }
                return Self.chapterIndexForSegmentItem(asset.url) == segmentChapterIndex
            }) else {
                skip(by: -positionSeconds)
                return
            }
            let remaining = Array(items[firstIndex...])
            queue.removeAllItems()
            var previous: AVPlayerItem?
            for item in remaining {
                queue.insert(item, after: previous)
                previous = item
            }
            queue.seek(to: .zero)
            segmentCumulativeBase = 0
            positionSeconds = 0
            queue.rate = isPlaying ? rate.rawValue : 0
        } else {
            queue.seek(to: .zero)
            positionSeconds = 0
        }
        broadcastPosition()
        updateNowPlayingInfo()
    }

    // MARK: Observers

    private func attachObservers() {
        guard let player else { return }
        if let item = player.currentItem {
            bindDurationObservers(to: item)
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rawTime = time.seconds.isFinite ? time.seconds : 0
                self.positionSeconds = self.isSegmentMode
                    ? self.segmentCumulativeBase + rawTime
                    : rawTime
                if let item = player.currentItem,
                   let dur = Self.validatedDurationSeconds(item.duration.seconds, isReadyToPlay: true) {
                    if self.isSegmentMode {
                        let queuedDuration = player.items().reduce(0.0) { total, queued in
                            guard let asset = queued.asset as? AVURLAsset else { return total }
                            let queuedChapter = Self.chapterIndexForSegmentItem(asset.url)
                            guard queuedChapter == self.segmentChapterIndex else { return total }
                            let value = queued.duration.seconds
                            return total + (value.isFinite && value > 0 ? value : 0)
                        }
                        let observed = self.segmentCumulativeBase + queuedDuration
                        let snapshotDuration = self.snapshot?.chapterProgress?
                            .first(where: {
                                $0.index == self.segmentChapterIndex
                                    || $0.index == self.segmentChapterIndex + 1
                            })?.durationSeconds ?? 0
                        self.segmentChapterDuration = max(
                            self.segmentChapterDuration,
                            observed,
                            self.segmentEstimatedDurations[self.segmentChapterIndex] ?? 0,
                            snapshotDuration.isFinite ? snapshotDuration : 0
                        )
                        self.durationSeconds = self.segmentChapterDuration
                    } else {
                        self.durationSeconds = dur
                    }
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
            guard let finishedItem = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                self?.handleFinishedItem(finishedItem)
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingProportionalSeek = nil
                if let item = self.player?.currentItem {
                    self.bindDurationObservers(to: item)
                } else {
                    self.itemObservationCancellables.removeAll()
                }
                let didReconcile = self.reconcileChapterIndexFromCurrentItem()
                // Only announce when the queue actually moved us to
                // a new chapter — KVO fires on buffer-ahead promotion
                // too, where the chapter index doesn't change.
                self.publishCurrentChapter(auto: didReconcile)
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Handles a natural AVPlayerItem completion. This is intentionally
    /// separate from NotificationCenter wiring so queue ownership and
    /// backpressure are testable without relying on AVFoundation timing.
    private func handleFinishedItem(_ finishedItem: AVPlayerItem) {
        let finishedID = ObjectIdentifier(finishedItem)
        let finishedDuration = finishedItem.duration.seconds
        let finishedIdentity: SegmentBacklog.Identity?
        if let asset = finishedItem.asset as? AVURLAsset {
            finishedIdentity = Self.segmentIdentityForSegmentItem(asset.url)
        } else {
            finishedIdentity = nil
        }

        // `object: nil` subscribes to every AVPlayerItem in the process. A
        // queue normally dequeues its finished current item before posting
        // the notification, so `items()` cannot establish ownership here.
        guard ownedPlayerItemIDs.remove(finishedID) != nil else { return }

        if isSegmentMode,
           finishedIdentity?.chapterIndex == segmentChapterIndex,
           finishedDuration.isFinite {
            // Notifications may arrive after KVO already promoted a later
            // chapter. Only the audible chapter's completed item can advance
            // its cumulative clock.
            segmentCumulativeBase += finishedDuration
        }

        drainPendingSegments()
        _ = activateCurrentSegmentItem()
        guard let snapshot else { return }
        let totalChapters = isSegmentMode
            ? (snapshot.chapterProgress?.count ?? 0)
            : (playbackChapters.isEmpty ? snapshot.playableChapters.count : playbackChapters.count)
        if !isSegmentMode, currentChapterIndex + 1 < totalChapters {
            // Snapshot the index BEFORE reconciling. `reconcile...` returns
            // false both when the URL is not found and when the index is
            // already correct after KVO promoted the next item.
            let indexBefore = currentChapterIndex
            _ = reconcileChapterIndexFromCurrentItem()
            if currentChapterIndex == indexBefore {
                currentChapterIndex += 1
                positionSeconds = 0
            }
            publishCurrentChapter(auto: true)
            updateNowPlayingInfo()
        } else if !isSegmentMode {
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    private func teardownPlayer() {
        cancelSegmentCapacityWaiters()
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
        // A segment is retained until it has been inserted into the queue or
        // this session ends. Teardown is the one intentional discard point:
        // no AVURLAsset from this player can still consume these files.
        _ = backlog.clear()
        segmentFiles.removeAll()
        segmentSentenceIDs.removeAll()
        segmentEstimatedDurations.removeAll()
        activeSegmentIdentity = nil
        segmentChapterIndex = -1
        segmentCumulativeBase = 0
        segmentChapterDuration = 0
        activeSentenceId = nil
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
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        remoteCommandRemovers.append { center.playCommand.removeTarget(playTarget) }

        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        remoteCommandRemovers.append { center.pauseCommand.removeTarget(pauseTarget) }

        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        remoteCommandRemovers.append { center.togglePlayPauseCommand.removeTarget(toggleTarget) }

        let nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        remoteCommandRemovers.append { center.nextTrackCommand.removeTarget(nextTarget) }

        let previousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        remoteCommandRemovers.append { center.previousTrackCommand.removeTarget(previousTarget) }

        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        remoteCommandRemovers.append { center.changePlaybackPositionCommand.removeTarget(positionTarget) }

        // Skip ±N seconds (Control Center, AirPods double-tap, lock-screen
        // arrow buttons). Both directions start at the product default.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))]
        let skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(by: e.interval) }
            return .success
        }
        remoteCommandRemovers.append { center.skipForwardCommand.removeTarget(skipForwardTarget) }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey))]
        let skipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(by: -e.interval) }
            return .success
        }
        remoteCommandRemovers.append { center.skipBackwardCommand.removeTarget(skipBackwardTarget) }

        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRate.allCases.map { NSNumber(value: $0.rawValue) }
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent,
                  let rate = PlaybackRate(rawValue: e.playbackRate) else {
                return .commandFailed
            }
            Task { @MainActor in self?.setRate(rate) }
            return .success
        }
        remoteCommandRemovers.append { center.changePlaybackRateCommand.removeTarget(rateTarget) }
    }

    /// Undo `configureRemoteCommands()` — removes every target this instance
    /// registered on the process-wide `MPRemoteCommandCenter` and deactivates
    /// the audio session if this instance activated it. Called from `deinit`
    /// so real playback state never outlives the `AudioPlayer` that created
    /// it (critical for XCTest, which constructs many real instances in one
    /// process on a physical device — see `remoteCommandRemovers` doc comment).
    /// `nonisolated` so `deinit` (non-isolated under Swift 6 on this
    /// `@MainActor` class) can call it directly, matching the rest of the
    /// teardown block above.
    nonisolated private func releaseSystemPlaybackResources() {
        for remove in remoteCommandRemovers { remove() }
        remoteCommandRemovers.removeAll()
        #if os(iOS)
        if audioSessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionConfigured = false
        }
        #endif
    }

    private func bindDurationObservers(to item: AVPlayerItem) {
        itemObservationCancellables.removeAll()

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                if let duration = Self.validatedDurationSeconds(
                    item.duration.seconds,
                    isReadyToPlay: status == .readyToPlay
                ) {
                    self.durationSeconds = duration
                    self.applyPendingProportionalSeek()
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &itemObservationCancellables)

        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] duration in
                guard let self, let item else { return }
                if let validated = Self.validatedDurationSeconds(
                    duration.seconds,
                    isReadyToPlay: item.status == .readyToPlay
                ) {
                    self.durationSeconds = validated
                    self.applyPendingProportionalSeek()
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &itemObservationCancellables)
    }

    /// Map `AVQueuePlayer.currentItem` back to the index of the chapter whose
    /// `downloadUrl` produced it. KVO fires before the end-of-item
    /// notification, so this is what keeps the lock-screen title in sync
    /// during auto-advance.
    ///
    /// Returns `true` when the chapter index actually changed —
    /// callers gate VoiceOver announcement on this so a KVO fire on
    /// buffer-ahead promotion (same chapter) doesn't double-speak.
    @discardableResult
    private func reconcileChapterIndexFromCurrentItem() -> Bool {
        guard
            let player,
            let item = player.currentItem,
            let urlAsset = item.asset as? AVURLAsset
        else { return false }
        if isSegmentMode {
            guard let identity = Self.segmentIdentityForSegmentItem(urlAsset.url) else {
                return false
            }
            let didChange = activateSegmentIdentity(identity)
            if didChange { positionSeconds = 0 }
            return didChange
        }
        guard let snapshot else { return false }
        let chapters = playbackChapters.isEmpty ? snapshot.playableChapters : playbackChapters
        let chapterURLs = chapters.map { chapter in
            absoluteURL(forDownloadPath: chapter.downloadUrl,
                        jobId: snapshot.jobId,
                        chapterIndex: chapter.index)
        }
        guard let idx = Self.resolveChapterIndex(
            currentIndex: currentChapterIndex,
            chapterURLs: chapterURLs,
            currentItemURL: urlAsset.url
        ) else { return false }
        guard idx != currentChapterIndex else { return false }
        currentChapterIndex = idx
        positionSeconds = 0
        return true
    }

    /// Build the Now Playing metadata dict. Extracted from
    /// `updateNowPlayingInfo()` so tests can assert on the metadata
    /// directly: `MPNowPlayingInfoCenter.default().nowPlayingInfo`
    /// does not round-trip reads in a headless xctest host (macOS or
    /// iOS simulator), so asserting through the singleton is flaky.
    func makeNowPlayingInfo() -> [String: Any] {
        var info: [String: Any] = [:]
        let bookTitle = snapshot?.bookTitle ?? "Epub-to-Mp3"
        let chapterTitle = effectiveChapterTitle
        // The chapter is the primary Now Playing label; the book remains
        // secondary metadata so Control Center and the lock screen identify
        // the exact text currently being read.
        info[MPMediaItemPropertyTitle] = chapterTitle
        info[MPMediaItemPropertyAlbumTitle] = bookTitle
        // The system player should identify the audiobook author when
        // available. Falling back to the book title keeps older backend
        // snapshots useful without emitting an empty artist field.
        info[MPMediaItemPropertyArtist] = snapshot?.bookAuthor ?? bookTitle
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
        return info
    }

    private func updateNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = makeNowPlayingInfo()
        syncWidgetNowPlaying()
    }

    /// Push the real playback state to the App Group so the home-screen /
    /// lock-screen widgets never show a stale play/pause affordance.
    /// Called from every site that already calls `updateNowPlayingInfo()`
    /// (play, pause, resume, chapter advance) — the single choke point for
    /// "did the transport state change" in this class. Previously only
    /// `PlaybackBindingStore.setCurrentlyPlaying` wrote to the widget, and only
    /// once, when a book was opened — the widget then never learned about
    /// a later pause, so it showed "pause" forever.
    /// Pure decision helper behind `syncWidgetNowPlaying()`: does the new
    /// (bookId, chapterName, isPlaying) tuple require a full, RELOADING
    /// `WidgetDataSync.updateNowPlaying` call, or can this tick get away
    /// with the reload-free `updateNowPlayingProgress`? Extracted so the
    /// dedup logic is unit-testable without spinning up a real
    /// `WidgetCenter`/App Group round-trip.
    nonisolated static func widgetSyncNeedsReload(
        last: (bookId: String, chapterName: String?, isPlaying: Bool)?,
        current: (bookId: String, chapterName: String?, isPlaying: Bool)
    ) -> Bool {
        guard let last else { return true }
        return last.bookId != current.bookId
            || last.chapterName != current.chapterName
            || last.isPlaying != current.isPlaying
    }

    private func syncWidgetNowPlaying() {
        let appGroupDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        guard let bookId = appGroupDefaults?.string(forKey: "currentlyPlayingBookId")
                ?? UserDefaults.standard.string(forKey: Self.currentBookIDDefaultsKey),
              !bookId.isEmpty else { return }
        let progress = durationSeconds > 0
            ? min(1, max(0, positionSeconds / durationSeconds))
            : 0
        let chapters = snapshot?.playableChapters ?? []
        let currentIndex = max(0, min(currentChapterIndex, max(chapters.count - 1, 0)))
        // Keep the widget on the same canonical title as the mini player and
        // Now Playing metadata. `currentChapterValue.displayTitle` can still
        // be the generated fallback when the reader has the real TOC title.
        let chapterName = effectiveChapterTitle
        let totalChapters = chapters.isEmpty ? nil : chapters.count
        let chapterRemaining = Self.rateAdjustedDuration(
            seconds: max(0, durationSeconds - positionSeconds), rate: rate
        )
        let followingRemaining = chapters.dropFirst(min(currentIndex + 1, chapters.count))
            .compactMap(\.durationSeconds)
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0) { total, duration in
                total + Self.rateAdjustedDuration(seconds: duration, rate: rate)
            }
        let bookRemaining = chapterRemaining + followingRemaining
        let timing = (
            position: playbackPositionSeconds,
            duration: playbackDurationSeconds,
                      chapterRemaining: chapterRemaining, bookRemaining: bookRemaining,
                      totalChapters: totalChapters)
        let state = (bookId: bookId, chapterName: chapterName, isPlaying: isPlaying)

        // Only pay for a `WidgetCenter.reloadTimelines` IPC round-trip when
        // the book, chapter, or transport state actually changed. A bare
        // progress tick (the common case — fires every ~1s during playback)
        // writes the new value without asking widgetkitd to rebuild.
        guard Self.widgetSyncNeedsReload(last: lastSyncedWidgetState, current: state) else {
            WidgetDataSync.updateNowPlayingProgress(progress)
            WidgetDataSync.updateNowPlayingTiming(
                positionSeconds: timing.position,
                durationSeconds: timing.duration,
                chapterRemainingSeconds: timing.chapterRemaining,
                bookRemainingSeconds: timing.bookRemaining,
                totalChapters: timing.totalChapters
            )
            return
        }
        lastSyncedWidgetState = state
        WidgetDataSync.updateNowPlaying(
            bookId: bookId,
            chapterName: chapterName,
            author: snapshot?.bookAuthor,
            progress: progress,
            isPlaying: isPlaying,
            positionSeconds: timing.position,
            durationSeconds: timing.duration,
            chapterRemainingSeconds: timing.chapterRemaining,
            bookRemainingSeconds: timing.bookRemaining,
            totalChapters: timing.totalChapters
        )
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
            do {
                try await Task.sleep(nanoseconds: stepNs)
            } catch is CancellationError {
                player.volume = originalVolume
                return
            } catch {
                player.volume = originalVolume
                return
            }
        }
        guard !sleepTimerCancelled else {
            player.volume = originalVolume
            return
        }
        pause()
        player.volume = originalVolume  // Restore for next session.
    }

    // MARK: Helpers

    /// Canonical chapter title for every playback surface: mini player,
    /// expanded player, Now Playing, lock screen and widget.
    var effectiveChapterTitle: String {
        // Before an audio queue exists, the compact player represents the
        // page the reader is showing, not the queue's default index zero.
        // This matters for books whose first readable EPUB entry is not the
        // first chapter the reader restores (for example, a table of contents
        // after an epigraph).
        if snapshot == nil,
           playbackChapters.isEmpty,
           let readerIndex = UserDefaults.standard.object(
               forKey: Self.readerCurrentChapterIndexDefaultsKey
           ) as? Int,
           let readerTitle = readerChapterTitles[readerIndex] {
            return Self.preferredChapterTitle(
                primary: readerTitle,
                secondary: nil,
                fallback: L10n.string("player.chapter", readerIndex + 1)
            )
        }
        if isSegmentMode {
            let streamedTitle = Self.segmentChapterTitle(
                chapterIndex: currentChapterIndex,
                chapterProgress: snapshot?.chapterProgress ?? []
            )
            return Self.preferredChapterTitle(
                primary: streamedTitle,
                secondary: readerChapterTitles[currentChapterIndex],
                fallback: streamedTitle
            )
        }
        let chapters = playbackChapters.isEmpty ? (snapshot?.playableChapters ?? []) : playbackChapters
        guard chapters.indices.contains(currentChapterIndex) else {
            let pending = Self.chapterProgressEntry(
                forSegmentIndex: currentChapterIndex,
                chapterProgress: snapshot?.chapterProgress ?? []
            )
            return Self.preferredChapterTitle(
                primary: pending?.name,
                secondary: readerChapterTitles[currentChapterIndex],
                fallback: pending?.displayTitle ?? L10n.string("player.chapter", currentChapterIndex + 1)
            )
        }
        let playing = chapters[currentChapterIndex]
        let progressName = snapshot?.chapterProgress?
            .first(where: { $0.index == playing.index })?.name
        // Reader fulltext indexes are zero-based while remote JobSnapshot
        // chapter indexes are one-based. Embedded snapshots use the former;
        // prefer the exact queue index and then the zero-based counterpart so
        // a real TOC title is not lost behind "Capítulo N".
        let readerName = readerChapterTitles[playing.index]
            ?? readerChapterTitles[playing.index - 1]
        return Self.preferredChapterTitle(
            primary: playing.name,
            secondary: readerName ?? progressName,
            fallback: playing.displayTitle
        )
    }

    func updateReaderChapterTitle(_ title: String, for index: Int) {
        guard !title.isEmpty else { return }
        readerChapterTitles[index] = title
        objectWillChange.send()
    }

    /// Installs every canonical TOC title as soon as the book is parsed.
    /// Conversion and playback can start before a reader controller exists,
    /// so this must not depend on a chapter becoming visible in the reader.
    func updateReaderChapterTitles(_ chapters: [EbookFulltext.Chapter]) {
        var titles: [Int: String] = [:]
        for chapter in chapters {
            let title = chapter.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            titles[chapter.zeroBasedEpubIndex] = title
        }
        guard !titles.isEmpty else { return }
        readerChapterTitles.merge(titles, uniquingKeysWith: { _, canonical in canonical })
        objectWillChange.send()
    }

    nonisolated static func preferredChapterTitle(
        primary: String?,
        secondary: String?,
        fallback: String
    ) -> String {
        let candidates = [primary, secondary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isGenericChapterTitle($0) }
            .map { stripGenericChapterPrefix($0) }
        return candidates.first ?? fallback
    }

    nonisolated static func isGenericChapterTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
            .replacingOccurrences(of: "á", with: "a")
            .replacingOccurrences(of: "í", with: "i")
        if normalized == "chapter" || normalized == "capitulo" { return true }
        for prefix in ["chapter ", "capitulo "] {
            if normalized.hasPrefix(prefix), Int(normalized.dropFirst(prefix.count)) != nil {
                return true
            }
        }
        return false
    }

    /// Strips a leading "Chapter N: "/"Capítulo N: " label from an
    /// otherwise-substantive title (e.g. an EPUB TOC entry the backend
    /// prefixed with its own numbering) — unlike `isGenericChapterTitle`,
    /// which only rejects titles that are PURELY the generic label. Now
    /// Playing / lock-screen metadata should show "The Shadow of the
    /// Past", not "Chapter 2: The Shadow of the Past".
    private nonisolated static func stripGenericChapterPrefix(_ title: String) -> String {
        let normalized = title.lowercased()
            .replacingOccurrences(of: "á", with: "a")
            .replacingOccurrences(of: "í", with: "i")
        for prefix in ["chapter ", "capitulo "] {
            guard normalized.hasPrefix(prefix) else { continue }
            let afterPrefix = normalized[normalized.index(normalized.startIndex, offsetBy: prefix.count)...]
            guard let colonRange = afterPrefix.range(of: ": ") else { continue }
            let numberPart = afterPrefix[afterPrefix.startIndex..<colonRange.lowerBound]
            guard Int(numberPart) != nil else { continue }
            // `normalized` is a 1-char-for-1-char transform of `title`
            // (lowercasing + single-accented-letter substitution never
            // changes character count), so the same character offset
            // slices the ORIGINAL (non-lowercased) string correctly.
            let prefixCharCount = prefix.count + numberPart.count + 2 // + ": "
            let stripped = String(title.dropFirst(prefixCharCount))
            return stripped.isEmpty ? title : stripped
        }
        return title
    }

    private var currentChapterValue: JobSnapshot.Chapter? {
        // SOURCE OF TRUTH: `currentChapterIndex` lives in playable-list
        // space. Resolving against `chapterProgress` by `$0.index ==
        // currentChapterIndex` would match an EPUB-index that happens
        // to share a numeric value with the playable index — wrong
        // chapter whenever any earlier chapter is unplayable. The
        // canonical lookup is `playableChapters[currentChapterIndex]`,
        // and we cross-reference back into `chapterProgress` by EPUB
        // index to surface any extra metadata the playable subset
        // dropped (rare; same struct today).
        if isSegmentMode {
            return snapshot?.chapterProgress?.first { $0.index == currentChapterIndex + 1 }
                ?? snapshot?.chapterProgress?.first { $0.index == currentChapterIndex }
        }
        let chapters = playbackChapters.isEmpty ? (snapshot?.playableChapters ?? []) : playbackChapters
        guard !chapters.isEmpty,
              chapters.indices.contains(currentChapterIndex) else { return nil }
        let playing = chapters[currentChapterIndex]
        if let progress = snapshot?.chapterProgress,
           let match = progress.first(where: { $0.index == playing.index }) {
            return match
        }
        return playing
    }

    /// Push the current-chapter value to all open AsyncStream
    /// subscribers. The `auto` flag controls whether VoiceOver gets a
    /// spoken announcement of the new chapter title — only true for
    /// auto-advance from the AVQueuePlayer's own auto-advance signal
    /// (KVO + end-of-item notification). User-initiated chapter
    /// changes (play, next, previous, TOC tap) already have the
    /// VoiceOver focus on a control that announces its own state, so
    /// announcing here would cause a double-speak.
    private func publishCurrentChapter(auto: Bool = false) {
        let value = currentChapterValue
        for cont in chapterContinuations.values { cont.yield(value) }
        #if os(iOS)
        if auto, let title = value?.displayTitle, !title.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: title)
        }
        #endif
    }

    private func broadcastPosition() {
        for cont in positionContinuations.values { cont.yield(positionSeconds) }
    }

    nonisolated static func resumePositionForPersistedState(
        positionSeconds: TimeInterval,
        wasPlaying: Bool
    ) -> TimeInterval {
        let position = max(0, positionSeconds)
        return wasPlaying ? max(0, position - 15) : position
    }

    func persistedResumeMarker(for jobId: String) -> ResumeMarker? {
        resumeStore.latestMarker(jobId: jobId)
    }

    func persistResumePoint(force: Bool) {
        guard let snapshot else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastResumePersist) < 5 { return }
        lastResumePersist = now
        let resumePosition = Self.resumePositionForPersistedState(
            positionSeconds: positionSeconds,
            wasPlaying: isPlaying
        )
        resumeStore.save(
            jobId: snapshot.jobId,
            chapterIndex: currentChapterIndex,
            position: resumePosition,
            wasPlaying: isPlaying,
            now: now
        )
        UserDefaults.standard.set(
            currentChapterIndex,
            forKey: Self.currentChapterIndexDefaultsKey
        )
    }

    /// Resolve a remote API path or local cached path to an audio URL.
    /// Backend paths must remain network URLs — treating `/api/...` as a
    /// filesystem path makes completed remote chapters silently unplayable.
    nonisolated static func playbackURL(forDownloadPath path: String?, backendBaseURL: URL?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        if path == "/api" || path.hasPrefix("/api/") {
            return backendBaseURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return backendBaseURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
    }

    private func absoluteURL(forDownloadPath path: String?, jobId: String? = nil, chapterIndex: Int? = nil) -> URL? {
        if let jobId, let chapterIndex,
           let local = DownloadManager.localAudioURL(jobId: jobId, chapterIndex: chapterIndex) {
            return local
        }
        return Self.playbackURL(forDownloadPath: path, backendBaseURL: backendBaseURL)
    }

    /// Embedded-runtime restart hook. Teardown the live AVQueuePlayer
    /// and reset segment-mode bookkeeping so the host can rebuild the
    /// queue from disk-cache starting at an arbitrary chapter. Keeps
    /// `firstSegmentReady` true so the transport UI stays mounted
    /// during the rebuild — flipping it off would briefly swap the
    /// player bar for the play-menu and jump the layout.
    /// Arms `pendingAutoPlay` so the very next `enqueueSegment` starts
    /// playback immediately, matching the user's "from beginning" /
    /// "previous chapter" intent.
    func prepareSegmentRestart(resumePosition: TimeInterval? = nil) {
        teardownPlayer()
        isSegmentMode = false
        segmentCumulativeBase = 0
        segmentChapterDuration = 0
        segmentChapterIndex = -1
        activeSegmentIdentity = nil
        activeSentenceId = nil
        pendingAutoPlay = true
        pendingSegmentResumePosition = resumePosition
        positionSeconds = 0
        isPlaying = false
    }

    /// Set by `prepareSegmentRestart` (and any future "play tap before
    /// segments arrive" surface) so the next `enqueueSegment` call
    /// flips the queue from rate 0 → rate.rawValue automatically,
    /// without waiting for a second user tap on the transport bar.
    private var pendingAutoPlay: Bool = false
    private var pendingSegmentResumePosition: TimeInterval?
    private var pendingPersistedResume: Bool = false

    func armPersistedResume() {
        pendingPersistedResume = true
    }

    func consumePersistedResumePosition(for jobId: String) -> TimeInterval? {
        guard pendingPersistedResume else { return nil }
        pendingPersistedResume = false
        return resumeStore.latestMarker(jobId: jobId)?.positionSeconds
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
    func testHook_playbackChapterCount() -> Int { playbackChapters.count }
    func testHook_setPendingProportionalSeek(_ ratio: Double?) {
        if let ratio {
            self.pendingProportionalSeek = .init(
                ratio: ratio,
                forChapterIndex: currentChapterIndex
            )
        } else {
            self.pendingProportionalSeek = nil
        }
    }
    func testHook_pendingProportionalSeek() -> Double? {
        pendingProportionalSeek?.ratio
    }
    func testHook_sentenceTimingMap(forChapterIndex idx: Int) -> [String: Int]? {
        sentenceTimingByChapter[idx]
    }
    func testHook_activeSegmentIdentity() -> SegmentBacklog.Identity? {
        activeSegmentIdentity
    }
    func testHook_deferredSegmentCount() -> Int { backlog.count }
    func testHook_retainedSegmentCount() -> Int { segmentFiles.count }
    func testHook_segmentURL(chapterIndex: Int, segmentIndex: Int) -> URL? {
        segmentFiles[.init(chapterIndex: chapterIndex, segmentIndex: segmentIndex)]
    }
    func testHook_activateSegment(chapterIndex: Int, segmentIndex: Int) {
        _ = activateSegmentIdentity(
            .init(chapterIndex: chapterIndex, segmentIndex: segmentIndex)
        )
    }
    func testHook_segmentChapterIndex() -> Int { segmentChapterIndex }
    func testHook_activeSegmentSentenceCount() -> Int {
        segmentFiles.keys.filter { $0.chapterIndex == segmentChapterIndex }.count
    }
    func testHook_activateSegmentChapter(_ chapterIndex: Int) {
        guard let identity = segmentFiles.keys
            .filter({ $0.chapterIndex == chapterIndex })
            .min() else { return }
        _ = activateSegmentIdentity(identity)
    }
    func testHook_bufferedSegmentChapterCount() -> Int {
        segmentFiles.keys.filter { $0.chapterIndex == segmentChapterIndex }.count
    }
    func testHook_completeSegmentTiming(chapterIndex: Int) {
        guard chapterIndex == segmentChapterIndex else { return }
        segmentCumulativeBase = max(segmentCumulativeBase, positionSeconds)
    }
    func testHook_registerOwnedSegmentItem(_ item: AVPlayerItem) {
        ownedPlayerItemIDs.insert(ObjectIdentifier(item))
    }
    func testHook_isOwnedSegmentItem(_ item: AVPlayerItem) -> Bool {
        ownedPlayerItemIDs.contains(ObjectIdentifier(item))
    }
    func testHook_removeOwnedSegmentItem(_ item: AVPlayerItem) {
        ownedPlayerItemIDs.remove(ObjectIdentifier(item))
    }
    func testHook_backlogCount() -> Int { backlog.count }
    func testHook_segmentCapacityWaiterCount() -> Int { segmentCapacityWaiters.count }
    nonisolated static func testHook_maxQueueAhead() -> Int { maxQueueAhead }
    func testHook_teardownPlayer() { teardownPlayer() }
    func testHook_finishCurrentSegment() -> Bool {
        guard let queue = player, let item = queue.currentItem else { return false }
        queue.advanceToNextItem()
        handleFinishedItem(item)
        return true
    }
    /// Simulate the post-`enqueueSegment` state in the embedded-runtime
    /// path: a live AVQueuePlayer carrying a synthesised MP3 with no
    /// snapshot-side `downloadUrl`. Used by the regression test for
    /// `playTapDecision` short-circuiting to `.resume` when there is
    /// nothing for the divergence dialog to resolve.
    func testHook_simulateSegmentMode() {
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
        self.player = queue
        self.isSegmentMode = true
    }
    #endif
}
