# Reader chrome visibility animation

An explicit center-tap viewport token now requests an opacity transition for
the reader navigation bar and its material. Initial setup, loading refreshes
and passive playback updates do not start a new fade. Reduced Motion uses a
short fade; the existing test launch override retains immediate transitions.

The navigation presenter changes opacity only when root owns layout. Root
still commits final constraints once and restores the captured raw contentOffset
through ReaderViewportTransition. TextKit and canonical pagination never use
intermediate animated heights or substitute a page boundary for that offset.

The shared VisibilityTransition completion gate is used by both chrome and
player overlays. Repeated targets preserve a pending completion; reversal
invalidates an old hide. This prevents a delayed completion from hiding newly
restored chrome or a playback refresh from resetting the fade. The previous
player-scoped state type moved to Shared/Presentation without changing its policy.

Foundation verification includes anchor capture/commit-order tests and
shared visibility policy tests. Native ReaderNavigationPresentationTests cover
opacity/layout separation, restoration and a real UIKit rapid reversal. Visible
seeded-EPUB checks, clipping/offset probes and iPhone acceptance remain deferred
to the user's final campaign. Required SE1/iOS 15.5 acceptance remains blocked
by Simulator quarantine. No visual success is inferred from Foundation tests.

References: [reader transition ADR](../../../docs/adr/2026-08-14-reader-viewport-transition.md),
[Apple Motion HIG](https://developer.apple.com/design/human-interface-guidelines/motion),
and [UIView animation options](https://developer.apple.com/documentation/uikit/uiview/animationoptions).
