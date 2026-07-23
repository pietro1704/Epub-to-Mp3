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
/// Persisted reader/player surface state. Values are namespaced by the
/// reader's book/job id so reopening one book cannot leak chrome state from
/// another. The expanded player flag is also mirrored globally by
/// `PlayerPresentation` because it is an app-wide overlay.
struct ReaderSessionState: Equatable {
    let chromeVisible: Bool
    let miniPlayerVisible: Bool
    let fullPlayerVisible: Bool

    static let `default` = ReaderSessionState(
        chromeVisible: true,
        miniPlayerVisible: true,
        fullPlayerVisible: false
    )

    private static func key(_ bookID: String, _ suffix: String) -> String {
        "reader.session.v1.\(bookID).\(suffix)"
    }

    static func load(bookID: String, defaults: UserDefaults = .standard) -> ReaderSessionState {
        guard defaults.object(forKey: key(bookID, "chromeVisible")) != nil else { return .default }
        return ReaderSessionState(
            chromeVisible: defaults.bool(forKey: key(bookID, "chromeVisible")),
            miniPlayerVisible: defaults.bool(forKey: key(bookID, "miniPlayerVisible")),
            fullPlayerVisible: defaults.bool(forKey: key(bookID, "fullPlayerVisible"))
        )
    }

    static func save(
        bookID: String,
        chromeVisible: Bool,
        miniPlayerVisible: Bool,
        fullPlayerVisible: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(chromeVisible, forKey: key(bookID, "chromeVisible"))
        defaults.set(miniPlayerVisible, forKey: key(bookID, "miniPlayerVisible"))
        defaults.set(fullPlayerVisible, forKey: key(bookID, "fullPlayerVisible"))
    }
}

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
