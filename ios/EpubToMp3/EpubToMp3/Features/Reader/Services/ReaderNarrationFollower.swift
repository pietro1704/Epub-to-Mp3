#if os(iOS)
import Combine
import Foundation

/// Connects the pure `ReaderFollowNarration` rules to a reader: it listens to the player's explicit jumps, is told
/// about manual page turns, and on every pairing refresh moves the reader to the spoken passage when it must.
@MainActor
final class ReaderNarrationFollower {
    private var rules = ReaderFollowNarration()
    private var jumps: AnyCancellable?
    private let player: AudioPlayer
    private let bookID: String
    private let reveal: (ReaderPlaybackLocation) -> Void
    /// Set while the reader moves itself, so a follow is never mistaken for a manual page turn.
    private(set) var isRevealing = false

    init(player: AudioPlayer, bookID: String, reveal: @escaping (ReaderPlaybackLocation) -> Void) {
        self.player = player
        self.bookID = bookID
        self.reveal = reveal
    }

    func start(onJump: @escaping () -> Void) {
        jumps = player.narrationJumps.sink { [weak self] in
            self?.rules.apply(.explicitNarrationJump)
            onJump()
        }
    }

    func stop() { jumps = nil }

    func userTurnedThePage() {
        guard !isRevealing else { return }
        rules.apply(.manualPageTurn)
    }

    /// The user asked to go to the narrated passage ("Go to reading").
    func userAskedToGoToReading() { rules.apply(.goToReading) }

    /// Call with the freshly computed pairing; moves the reader when the narration left the visible page.
    func evaluate(paired: Bool) {
        let narrating = player.isPlaying && player.isPlaybackForReaderBook(bookID)
        guard rules.shouldFollow(paired: paired, isNarrating: narrating),
              let location = ReaderPlaybackLocation(player: player) else { return }
        isRevealing = true
        defer { isRevealing = false }
        reveal(location)
    }
}
#endif
