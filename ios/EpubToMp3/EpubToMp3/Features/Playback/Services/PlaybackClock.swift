import Combine
import Foundation

/// High-frequency playback state shared only by transport surfaces.
///
/// `AudioPlayer` owns commands, queue state, and chapter state. Its periodic
/// AVPlayer observer updates this object instead of publishing through the
/// global player object, so library and reader views do not redraw every
/// quarter second while audio is playing.
@MainActor
final class PlaybackClock: ObservableObject {
    struct Snapshot: Equatable {
        let positionSeconds: TimeInterval
        let durationSeconds: TimeInterval
        let sleepTimerRemaining: TimeInterval

        static let zero = Snapshot(
            positionSeconds: 0,
            durationSeconds: 0,
            sleepTimerRemaining: 0
        )
    }

    @Published private(set) var snapshot: Snapshot = .zero

    var positionSeconds: TimeInterval { snapshot.positionSeconds }
    var durationSeconds: TimeInterval { snapshot.durationSeconds }
    var sleepTimerRemaining: TimeInterval { snapshot.sleepTimerRemaining }

    func update(
        positionSeconds: TimeInterval? = nil,
        durationSeconds: TimeInterval? = nil,
        sleepTimerRemaining: TimeInterval? = nil
    ) {
        let next = Snapshot(
            positionSeconds: positionSeconds ?? snapshot.positionSeconds,
            durationSeconds: durationSeconds ?? snapshot.durationSeconds,
            sleepTimerRemaining: sleepTimerRemaining ?? snapshot.sleepTimerRemaining
        )
        guard next != snapshot else { return }
        snapshot = next
    }

    func reset() {
        guard snapshot != .zero else { return }
        snapshot = .zero
    }
}
