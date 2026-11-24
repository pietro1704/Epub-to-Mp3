import Combine
import Foundation

/// Connects the pure `ReaderFollowNarration` rules to a reader: it listens to the player's explicit jumps, is told
/// about manual page turns, and on every pairing refresh asks the reader to move to the spoken passage when it must.
/// Platform-neutral: the reader supplies how to read the narration state and how to move itself.
@MainActor
final class ReaderNarrationFollower {
    private var rules = ReaderFollowNarration()
    private var subscription: AnyCancellable?
    private let jumps: AnyPublisher<Void, Never>
    private let isNarrating: () -> Bool
    private let follow: () -> Void
    /// Set while the reader moves itself, so a follow is never mistaken for a manual page turn.
    private(set) var isRevealing = false

    /// - Parameters:
    ///   - jumps: fires when the user moves the narration itself (seek, skip, chapter, play-from-here).
    ///   - isNarrating: true while this reader's book is being narrated (playing).
    ///   - follow: moves the reader to the spoken passage.
    init(jumps: AnyPublisher<Void, Never>, isNarrating: @escaping () -> Bool, follow: @escaping () -> Void) {
        self.jumps = jumps
        self.isNarrating = isNarrating
        self.follow = follow
    }

    var isSuspended: Bool { rules.isSuspended }

    func start(onJump: @escaping () -> Void) {
        subscription = jumps.sink { [weak self] in
            self?.rules.apply(.explicitNarrationJump)
            onJump()
        }
    }

    func stop() { subscription = nil }

    func userTurnedThePage() {
        guard !isRevealing else { return }
        rules.apply(.manualPageTurn)
    }

    /// The user asked to go to the narrated passage ("Go to reading").
    func userAskedToGoToReading() { rules.apply(.goToReading) }

    /// Call with the freshly computed pairing; moves the reader when the narration left the visible page.
    func evaluate(paired: Bool) {
        guard rules.shouldFollow(paired: paired, isNarrating: isNarrating()) else { return }
        isRevealing = true
        defer { isRevealing = false }
        follow()
    }
}

#if os(iOS)
extension ReaderNarrationFollower {
    /// The follower of an iOS reader: it follows `player` while it narrates `bookID`.
    convenience init(player: AudioPlayer, bookID: String, reveal: @escaping (ReaderPlaybackLocation) -> Void) {
        self.init(
            jumps: player.narrationJumps.eraseToAnyPublisher(),
            isNarrating: { player.isPlaying && player.isPlaybackForReaderBook(bookID) },
            follow: {
                guard let location = ReaderPlaybackLocation(player: player) else { return }
                reveal(location)
            })
    }
}
#endif
