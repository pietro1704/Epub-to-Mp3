import Foundation
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Owns process-wide command registrations and audio-session observer lifetimes.
/// Actions emit intent to the sole AudioPlayer coordinator through weak captures.
@MainActor
final class PlaybackSystemSession {
    struct Actions {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let next: () -> Void
        let previous: () -> Void
        let seek: (TimeInterval) -> Void
        let skip: (TimeInterval) -> Void
        let setRate: (PlaybackRate) -> Void
        let interruption: (UInt?, UInt) -> Void
        let routeChange: (Int?) -> Void
        let mediaServicesReset: () -> Void
    }
    private let actions: Actions
    private var wasPlayingBeforeInterruption = false
    private var remoteCommandsConfigured = false
    // `nonisolated(unsafe)` (matching `player`/`timeObserverToken`/`endObserver`
    // above) so `deinit` — non-isolated under Swift 6 on a `@MainActor` class —
    // can read/reset it from `releaseSystemPlaybackResources()`. Every mutator
    // besides deinit still runs on MainActor, so there is no concurrent writer.
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
    nonisolated(unsafe) private var audioSessionConfigured = false
    private let audioSessionObservation = PlaybackAudioSessionObservation()
    // Every addTarget stores its exact removal thunk. Registrations must not
    // outlive the owner, especially when XCTest creates multiple players.
    nonisolated(unsafe) private var remoteCommandRemovers: [() -> Void] = []

    init(actions: Actions) { self.actions = actions }
    deinit { releaseResources() }

    func invalidateAudioSession() {
        audioSessionConfigured = false
        audioSessionObservation.invalidate()
    }
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

    func ensureAudioSession() {
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
        audioSessionObservation.install(names: .init(
            interruption: AVAudioSession.interruptionNotification,
            routeChange: AVAudioSession.routeChangeNotification,
            mediaServicesReset: AVAudioSession.mediaServicesWereResetNotification,
            interruptionTypeKey: AVAudioSessionInterruptionTypeKey,
            interruptionOptionsKey: AVAudioSessionInterruptionOptionKey,
            routeChangeReasonKey: AVAudioSessionRouteChangeReasonKey
        ), object: AVAudioSession.sharedInstance(),
            interruption: { [weak self] in self?.actions.interruption($0, $1) },
            routeChange: { [weak self] in self?.actions.routeChange($0) },
            reset: { [weak self] in self?.actions.mediaServicesReset() })
        #endif
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.actions.play() }
            return .success
        }
        remoteCommandRemovers.append { center.playCommand.removeTarget(playTarget) }

        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.actions.pause() }
            return .success
        }
        remoteCommandRemovers.append { center.pauseCommand.removeTarget(pauseTarget) }

        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.actions.toggle() }
            return .success
        }
        remoteCommandRemovers.append { center.togglePlayPauseCommand.removeTarget(toggleTarget) }

        let nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.actions.next() }
            return .success
        }
        remoteCommandRemovers.append { center.nextTrackCommand.removeTarget(nextTarget) }

        let previousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.actions.previous() }
            return .success
        }
        remoteCommandRemovers.append { center.previousTrackCommand.removeTarget(previousTarget) }

        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.actions.seek(event.positionTime) }
            return .success
        }
        remoteCommandRemovers.append { center.changePlaybackPositionCommand.removeTarget(positionTarget) }

        // Skip ±N seconds (Control Center, AirPods double-tap, lock-screen
        // arrow buttons). Both directions start at the product default.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))]
        let skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.actions.skip(e.interval) }
            return .success
        }
        remoteCommandRemovers.append { center.skipForwardCommand.removeTarget(skipForwardTarget) }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey))]
        let skipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.actions.skip(-e.interval) }
            return .success
        }
        remoteCommandRemovers.append { center.skipBackwardCommand.removeTarget(skipBackwardTarget) }

        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRate.primaryRates.map { NSNumber(value: $0.rawValue) }
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent,
                  let rate = PlaybackRate(rawValue: e.playbackRate) else {
                return .commandFailed
            }
            Task { @MainActor in self?.actions.setRate(rate) }
            return .success
        }
        remoteCommandRemovers.append { center.changePlaybackRateCommand.removeTarget(rateTarget) }
    }

    static func configuredSkipInterval(forKey key: String) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double
        return AppSettings.playbackSkipIntervals.contains(value ?? 15) ? (value ?? 15) : 15
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
    nonisolated func releaseResources() {
        audioSessionObservation.invalidate()
        for remove in remoteCommandRemovers { remove() }
        remoteCommandRemovers.removeAll()
        #if os(iOS)
        if audioSessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionConfigured = false
        }
        #endif
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
    #if os(iOS)
    func interruptionAction(typeRaw: UInt?, optionRaw: UInt, isPlaying: Bool) -> InterruptionRecoveryAction {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return .none }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            return isPlaying ? .pause : .none
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume)
            guard shouldResume, wasPlayingBeforeInterruption else { return .none }
            ensureAudioSession()
            wasPlayingBeforeInterruption = false
            return .resume
        @unknown default: return .none
        }
    }
    func recoverMediaServices(isPlaying: Bool) -> Bool {
        let shouldResume = isPlaying || wasPlayingBeforeInterruption
        invalidateAudioSession()
        guard shouldResume else { return false }
        ensureAudioSession()
        return true
    }
    #endif

    static func refreshSkipIntervals() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey))]
    }

}
