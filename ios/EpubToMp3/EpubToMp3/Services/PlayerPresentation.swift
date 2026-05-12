import Foundation

/// Controls the global full-player sheet presentation state.
/// A single shared instance is injected into the environment by
/// `EpubToMp3App` via `@StateObject`. Every surface that can open
/// the full-player (MiniPlayerBar, keyboard shortcut, deep link) reads
/// this object instead of passing callbacks through the view tree.
///
/// Usage:
///   @EnvironmentObject private var playerPresentation: PlayerPresentation
///   playerPresentation.showFullPlayer()
final class PlayerPresentation: ObservableObject {
    @Published var showingFullPlayer: Bool = false

    func showFullPlayer() {
        showingFullPlayer = true
    }

    func dismissFullPlayer() {
        showingFullPlayer = false
    }
}
