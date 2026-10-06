import Foundation

/// Coordinates one reader chrome transaction from anchor capture through the
/// final viewport commit. The owner supplies its layout work as closures so
/// this module stays independent of UIKit and of any particular content view.
@MainActor
final class ReaderViewportTransition {
    struct Token: Equatable, Hashable {
        fileprivate let generation: UInt
    }

    private var nextGeneration: UInt = 0
    private var activeToken: Token?
    private(set) var targetChromeHidden: Bool?

    var isActive: Bool { activeToken != nil }

    /// Starts, or idempotently returns, the transaction for the requested
    /// chrome state. Anchor capture runs once across rapid replacement
    /// requests, preserving the raw pre-transition viewport offset.
    @discardableResult
    func begin(to chromeHidden: Bool, captureAnchor: () -> Void) -> Token {
        if let activeToken, targetChromeHidden == chromeHidden {
            return activeToken
        }

        let capturesAnchor = activeToken == nil
        nextGeneration &+= 1
        let token = Token(generation: nextGeneration)
        activeToken = token
        targetChromeHidden = chromeHidden
        if capturesAnchor {
            captureAnchor()
        }
        return token
    }

    /// Applies final geometry and restores the captured viewport only when
    /// this token still represents the newest requested chrome state.
    @discardableResult
    func commit(
        _ token: Token,
        applyFinalGeometry: () -> Void,
        restoreViewport: () -> Void
    ) -> Bool {
        guard activeToken == token else { return false }
        applyFinalGeometry()
        guard activeToken == token else { return false }
        restoreViewport()
        guard activeToken == token else { return false }
        activeToken = nil
        targetChromeHidden = nil
        return true
    }

    /// Invalidates an outstanding transaction when its reader disappears or
    /// is replaced. Any later completion carrying its token becomes stale.
    func cancel() {
        nextGeneration &+= 1
        activeToken = nil
        targetChromeHidden = nil
    }
}
