import Foundation

/// Controls global full-player presentation state for native UIKit/AppKit
/// controllers. Combine publishes changes so every platform surface can
/// refresh without a SwiftUI view tree or duplicated presentation state.
@MainActor
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
