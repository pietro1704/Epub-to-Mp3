#if os(iOS)
import UIKit

/// Owns reader presentation facts and viewport-transition generations at the root seam.
@MainActor
final class ReaderRootPresentationCoordinator {
    private(set) var state = ReaderPresentationState()
    private let viewportTransition = ReaderViewportTransition()
    private weak var rootView: UIView?
    private var readerBottomToMiniPlayer: NSLayoutConstraint?
    private var readerBottomToRoot: NSLayoutConstraint?
    private var bottomChromeInitialized = false
    private var bottomChromeHidden = false

    func configureChromeLayout(
        rootView: UIView,
        readerBottomToMiniPlayer: NSLayoutConstraint,
        readerBottomToRoot: NSLayoutConstraint
    ) {
        self.rootView = rootView
        self.readerBottomToMiniPlayer = readerBottomToMiniPlayer
        self.readerBottomToRoot = readerBottomToRoot
    }

    func beginChromeTransition(to isHidden: Bool, captureViewport: () -> Void) -> ReaderViewportTransition.Token {
        let token = viewportTransition.begin(to: isHidden, captureAnchor: captureViewport)
        state.isChromeHidden = isHidden
        return token
    }

    func setLoading(_ isLoading: Bool) -> Bool {
        guard state.isLoading != isLoading else { return false }
        state.isLoading = isLoading
        return true
    }

    func setReaderActive(_ isActive: Bool) {
        if !isActive {
            guard state.isReaderActive || state.isLoading || state.isChromeHidden || viewportTransition.isActive else {
                return
            }
            // The reader can disappear while a chrome request is waiting for
            // its final layout. Its later completion must not restore an
            // offset into an inactive or replacement reader.
            viewportTransition.cancel()
            state.resetForInactiveReader()
            return
        }
        state.isReaderActive = true
    }

    func applyChromeLayout(
        transition: ReaderViewportTransition.Token?,
        needsFinalLayout: Bool,
        restoreViewport: () -> Void
    ) {
        guard let rootView, let readerBottomToMiniPlayer, let readerBottomToRoot else { return }
        let hidesBottomChrome = state.hidesBottomChrome
        NSLayoutConstraint.deactivate([readerBottomToMiniPlayer, readerBottomToRoot])
        (hidesBottomChrome ? readerBottomToRoot : readerBottomToMiniPlayer).isActive = true
        let changed = !bottomChromeInitialized || bottomChromeHidden != hidesBottomChrome
        bottomChromeInitialized = true
        bottomChromeHidden = hidesBottomChrome
        _ = commit(
            transition,
            applyFinalGeometry: {
                UIView.performWithoutAnimation { rootView.layoutIfNeeded() }
            },
            restoreViewport: restoreViewport,
            needsFinalLayout: changed || needsFinalLayout
        )
    }

    @discardableResult
    func commit(
        _ token: ReaderViewportTransition.Token?,
        applyFinalGeometry: () -> Void,
        restoreViewport: () -> Void,
        needsFinalLayout: Bool
    ) -> Bool {
        if let token {
            return viewportTransition.commit(
                token,
                applyFinalGeometry: applyFinalGeometry,
                restoreViewport: restoreViewport
            )
        }
        guard needsFinalLayout else { return false }
        applyFinalGeometry()
        restoreViewport()
        return true
    }
}
#endif
