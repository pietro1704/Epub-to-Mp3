import Foundation

/// Controls the global full-player sheet presentation state.
/// A single shared instance is injected into the environment by
/// `EpubToMp3App` via `@StateObject`. Every surface that can open
/// the full-player (native mini-player, keyboard shortcut, deep link) reads
/// this object instead of passing callbacks through the view tree.
///
/// Usage:
///   @EnvironmentObject private var playerPresentation: PlayerPresentation
///   playerPresentation.showFullPlayer()
final class PlayerPresentation: ObservableObject {
    static let persistedExpandedKey = "player.presentation.expanded.v1"

    @Published var showingFullPlayer: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showingFullPlayer = defaults.bool(forKey: Self.persistedExpandedKey)
    }

    func showFullPlayer() {
        showingFullPlayer = true
        defaults.set(true, forKey: Self.persistedExpandedKey)
    }

    func dismissFullPlayer() {
        showingFullPlayer = false
        defaults.set(false, forKey: Self.persistedExpandedKey)
    }
}
