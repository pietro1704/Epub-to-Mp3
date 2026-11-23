import Foundation
#if os(iOS)
import UIKit
#endif

/// Bounded background-execution window held only while the user wants audio,
/// on-device synthesis is still producing the next segment, and the player has
/// run dry. With `UIBackgroundModes=audio` the process is kept alive by audible
/// output; once the drained queue stops rendering, iOS may suspend the app and
/// the Rust synthesis thread (blocked on or feeding the main actor) with it.
/// The window lets synthesis deliver the next segment, after which rendering
/// keeps the process alive again. It never grows past the system allowance: it
/// ends when rendering resumes, intent or synthesis ends, or iOS expires it.
@MainActor
final class PlaybackStarvationWindow {
    typealias Begin = (_ name: String, _ expired: @escaping @MainActor () -> Void) -> Int?
    typealias End = (Int) -> Void

    private let begin: Begin
    private let end: End
    private var token: Int?
    /// After an expiry, do not request another window until audio renders
    /// again; a second request would only churn against the system limit.
    private var expiredWhileStarved = false
    var isHeld: Bool { token != nil }

    // Default arguments are evaluated outside the main actor, so the
    // main-actor system hooks are chosen inside the isolated initializer.
    init(begin: Begin? = nil, end: End? = nil) {
        self.begin = begin ?? Self.systemBegin
        self.end = end ?? Self.systemEnd
    }

    func update(wantsAudio: Bool, awaitingSynthesis: Bool, isRendering: Bool) {
        if isRendering { expiredWhileStarved = false }
        guard wantsAudio, awaitingSynthesis, !isRendering else { release(); return }
        guard token == nil, !expiredWhileStarved else { return }
        token = begin("Playback awaiting synthesized audio") { [weak self] in
            guard let self else { return }
            self.expiredWhileStarved = true
            self.release()
        }
    }

    func release() {
        guard let token else { return }
        self.token = nil
        end(token)
    }

    static let systemBegin: Begin = { name, expired in
        #if os(iOS)
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            PlaybackTrace.shared.record("starvation window expired by iOS")
            Task { @MainActor in expired() }
        }
        PlaybackTrace.shared.record("starvation window begin granted=\(id != .invalid) "
            + "bgRemaining=\(PlaybackTrace.backgroundTimeRemaining())")
        return id == .invalid ? nil : id.rawValue
        #else
        return nil
        #endif
    }

    static let systemEnd: End = { token in
        #if os(iOS)
        PlaybackTrace.shared.record("starvation window ended")
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        #endif
    }
}
