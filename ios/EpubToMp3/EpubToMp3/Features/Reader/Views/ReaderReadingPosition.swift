#if os(iOS)
import UIKit

/// Preserves reading passage and exact raw offsets across host viewport changes.
/// Canonical page offsets remain exclusively owned by ReaderTextViewport.
@MainActor
final class ReaderReadingPosition {
    struct Facts {
        let chromeHidden: Bool
        let isPaginated: Bool
        let isLoading: Bool
        let layoutResult: ReaderPaginatedTextLayout.Result?
    }
    enum Event {
        case requestTextLayoutRefresh, updatePaginationProbe, updatePageIndicator
        case updateTextHeightForCurrentLayout
        case prepareProjection(Int)
    }
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let facts: () -> Facts
    private let send: (Event) -> Void
    let playback: ReaderPlaybackPosition

    init(document: ReaderBookDocument, composition: ReaderViewComposition,
         facts: @escaping () -> Facts, send: @escaping (Event) -> Void) {
        self.document = document
        self.composition = composition
        self.facts = facts
        self.send = send
        playback = ReaderPlaybackPosition(document: document, composition: composition)
    }

    struct ReadingAnchor {
        let offsetFraction: CGFloat
        let characterOffset: Int?
        /// The chrome transition only changes viewport height. Preserve its
        /// exact vertical origin instead of reinterpreting it as a different
        /// paginated boundary.
        let viewportOffset: CGFloat?

        init(offsetFraction: CGFloat, characterOffset: Int?, viewportOffset: CGFloat? = nil) {
            self.offsetFraction = offsetFraction
            self.characterOffset = characterOffset
            self.viewportOffset = viewportOffset
        }
    }

    /// A paginated page boundary depends on the complete viewport geometry.
    /// Keep the exact offset a reader saw for each chrome state so an
    /// on/off round trip returns to that same page instead of re-rounding the
    /// passage to a nearby page boundary on every reflow.
    private struct ViewportAnchorKey: Hashable {
        let chromeHidden: Bool
        let width: Int
        let height: Int
    }

    private(set) var pendingViewportAnchor: ReadingAnchor?
    private var rawViewportOffsets: [ViewportAnchorKey: CGFloat] = [:]
    private var chromeVisibleRawViewportOffset: CGFloat?
    private var rememberedViewportOffsets: [ViewportAnchorKey: (character: Int, offset: CGFloat)] = [:]
    /// Page offsets are invalid while the host is animating a chrome-driven
    /// viewport resize. Serializing input avoids splitting TextKit lines.
    private(set) var isViewportTransitioning = false
    func forgetViewportOffsets() { rememberedViewportOffsets.removeAll() }

    func persistReadingProgress() {
        let anchor = captureReadingAnchor()
        rememberViewportOffset(for: anchor)
        playback.publish(anchor, facts: facts(), isViewportTransitioning: isViewportTransitioning)
        ReaderProgressStore.save(
            bookId: document.book.id,
            chapterIndex: document.selectedChapter,
            offsetFraction: Double(anchor.offsetFraction),
            characterOffset: anchor.characterOffset
        )
        if document.fulltext != nil { send(.prepareProjection(document.selectedChapter)) }
    }

    func captureReadingAnchor() -> ReadingAnchor {
        let scrollable = max(
            composition.scrollView.contentSize.height + composition.scrollView.contentInset.bottom - composition.scrollView.bounds.height,
            1
        )
        // A chrome restore can intentionally start on a TextKit line that is
        // not one of the global page-turn boundaries. Replacing that visible
        // offset with the preceding global boundary makes every subsequent
        // chrome tap capture an earlier passage and progressively walk the
        // reader backwards.
        let visibleOffset = composition.scrollView.contentOffset.y
        let fraction = min(max(visibleOffset / scrollable, 0), 1)
        let characterOffset: Int? = { () -> Int? in
            guard composition.textView.attributedText.length > 0 else { return nil }
            if facts().isPaginated {
                // Capture the first complete line at or below the actual
                // viewport edge. The viewport may have a line-based restore
                // offset rather than a global page-turn boundary.
                let fullRange = composition.textView.layoutManager.glyphRange(for: composition.textView.textContainer)
                var character: Int?
                let epsilon: CGFloat = 0.5
                composition.textView.layoutManager.enumerateLineFragments(forGlyphRange: fullRange) {
                    lineRect, _, _, glyphRange, stop in
                    guard glyphRange.length > 0,
                          lineRect.minY >= visibleOffset - self.composition.textView.textContainerInset.top - epsilon else { return }
                    character = self.composition.textView.layoutManager.characterIndexForGlyph(at: glyphRange.location)
                    stop.pointee = true
                }
                return character
            }
            let visibleRect = CGRect(
                x: 0,
                y: max(0, visibleOffset),
                width: composition.textView.textContainer.size.width,
                height: composition.scrollView.bounds.height
            )
            let glyphRange = composition.textView.layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: composition.textView.textContainer
            )
            guard glyphRange.length > 0 else { return nil }
            return composition.textView.layoutManager.characterIndexForGlyph(at: glyphRange.location)
        }()
        return ReadingAnchor(
            offsetFraction: fraction,
            characterOffset: characterOffset,
            viewportOffset: visibleOffset
        )
    }

    func restoreReadingAnchor(_ anchor: ReadingAnchor, preservingViewportOffset: Bool = false) {
        let scrollable = max(
            composition.scrollView.contentSize.height + composition.scrollView.contentInset.bottom - composition.scrollView.bounds.height,
            0
        )
        guard scrollable > 0 else { return }
        let candidate: CGFloat
        if preservingViewportOffset, let viewportOffset = anchor.viewportOffset {
            candidate = viewportOffset
        } else if let characterOffset = anchor.characterOffset, composition.textView.attributedText.length > 0 {
            let safeOffset = min(characterOffset, composition.textView.attributedText.length - 1)
            let glyph = composition.textView.layoutManager.glyphIndexForCharacter(at: safeOffset)
            let lineRect = composition.textView.layoutManager.lineFragmentRect(
                forGlyphAt: glyph,
                effectiveRange: nil
            )
            // A glyph's bounding box excludes the line's leading. Restoring
            // to that smaller rect leaves the top of the first rendered line
            // above the viewport after a chrome reflow. Use the complete
            // TextKit line fragment, preserving the passage without clipping.
            candidate = max(0, lineRect.minY + composition.textView.textContainerInset.top)
        } else {
            candidate = anchor.offsetFraction * scrollable
        }
        // A saved glyph anchor is not necessarily a valid paginated page
        // boundary. Snap it to the layout-generated page start; restoring to
        // an arbitrary line only protects the top edge and can crop the last
        // visible line after chrome or safe-area reflow.
        let target: CGFloat
        if !preservingViewportOffset,
           facts().isPaginated,
           let characterOffset = anchor.characterOffset,
           let remembered = rememberedViewportOffsets[viewportAnchorKey()],
           remembered.character == characterOffset {
            // This exact chrome geometry has already displayed this passage.
            // Reusing its measured page start makes a chrome round trip
            // perfectly reversible instead of progressively rounding back.
            target = remembered.offset
        } else {
            // The visible TextKit line is the reading anchor. Global page
            // boundaries differ between chrome geometries, so rounding this
            // line down moves backwards and rounding it up moves forwards on
            // every toggle. Keep the line itself at the viewport top; the
            // glyph-aware overflow guard suppresses only an incomplete final
            // line, never the anchored passage.
            target = candidate
        }
        let appliedOffset = min(max(0, target), scrollable)
        composition.scrollView.setContentOffset(CGPoint(x: 0, y: appliedOffset), animated: false)
        // `target` may be the preceding canonical boundary when a line that
        // was first in the old viewport no longer starts a page in the new
        // geometry. Cache the anchor that is actually on screen, never the
        // requested one: associating the old character with that preceding
        // offset poisons later chrome round trips and walks the reader back.
        rememberViewportOffset(for: captureReadingAnchor())
        // `setContentOffset` does not reliably produce a layout pass. Refresh
        // the XCTest-only probe after the restore so it reports the page that
        // is actually on screen rather than the page from before reflow.
        send(.updatePaginationProbe)
    }

    private func viewportAnchorKey() -> ViewportAnchorKey {
        let scale = composition.view.window?.screen.scale ?? UIScreen.main.scale
        return ViewportAnchorKey(
            chromeHidden: facts().chromeHidden,
            width: Int((composition.scrollView.bounds.width * scale).rounded()),
            height: Int((composition.scrollView.bounds.height * scale).rounded())
        )
    }

    private func rememberViewportOffset(for anchor: ReadingAnchor) {
        guard facts().isPaginated,
              let character = anchor.characterOffset,
              composition.scrollView.bounds.width > 0,
              composition.scrollView.bounds.height > 0 else { return }
        rememberedViewportOffsets[viewportAnchorKey()] = (
            character: character,
            offset: composition.textViewport.pageOffset(for: composition.textViewport.pageNumber(at: composition.scrollView.contentOffset.y))
        )
    }

    /// The parent reader changes its top and bottom anchors while entering
    /// immersive mode. Capture the current glyph before that reflow and
    /// restore it after TextKit has measured the larger viewport.
    func prepareForViewportTransition() {
        guard composition.loadingContainer.isHidden,
              composition.scrollView.bounds.height > 0 else { return }
        // Both the reader and its host prepare the same constraint change.
        // The host call happens after the child has swapped its local
        // constraints, when UIKit may already have clamped the scroll view.
        // Preserve the first (pre-mutation) anchor for this transaction.
        // The root transition coordinator has already deduplicated requests.
        // A stale child anchor must never suppress the fresh raw capture for a
        // new chrome transaction; doing so restores an earlier clamped page.
        pendingViewportAnchor = captureReadingAnchor()
        rawViewportOffsets[viewportAnchorKey()] = composition.scrollView.contentOffset.y
        if !facts().chromeHidden {
            chromeVisibleRawViewportOffset = composition.scrollView.contentOffset.y
        }
        isViewportTransitioning = true
        send(.requestTextLayoutRefresh)
    }

    func restorePendingViewportAnchorIfNeeded(preservingViewportOffset: Bool = false) {
        guard let anchor = pendingViewportAnchor,
              composition.scrollView.bounds.height > 0,
              !isViewportTransitioning else { return }
        pendingViewportAnchor = nil
        restoreReadingAnchor(anchor, preservingViewportOffset: preservingViewportOffset)
        send(.updatePageIndicator)
    }

    /// The parent invokes this after its navigation-bar animation reaches
    /// final geometry. Only then are the current page offsets safe to use.
    func completeViewportTransition() {
        guard isViewportTransitioning else { return }
        composition.view.setNeedsLayout()
        composition.view.layoutIfNeeded()
        send(.updateTextHeightForCurrentLayout)
        // The root has committed its constraints, but UIKit can still expose
        // the previous child-scroll bounds until the next main-loop layout.
        // Restoring a raw offset against that stale height clamps it and makes
        // a later chrome round trip walk backward.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewportTransitioning else { return }
            self.composition.view.setNeedsLayout()
            self.composition.view.layoutIfNeeded()
            self.send(.updateTextHeightForCurrentLayout)
            self.finishViewportTransitionRestore()
        }
    }

    private func finishViewportTransitionRestore() {
        if let anchor = pendingViewportAnchor,
           let rawOffset = !facts().chromeHidden
                ? chromeVisibleRawViewportOffset
                : rawViewportOffsets[viewportAnchorKey()]
                    ?? rawViewportOffsets.first(where: { $0.key.chromeHidden == facts().chromeHidden })?.value {
            pendingViewportAnchor = ReadingAnchor(
                offsetFraction: anchor.offsetFraction,
                characterOffset: anchor.characterOffset,
                viewportOffset: rawOffset
            )
        }
        isViewportTransitioning = false
        restorePendingViewportAnchorIfNeeded(preservingViewportOffset: true)
        UIAccessibility.post(notification: .layoutChanged, argument: composition.textView)
    }

    /// Called once, right after a fresh `loadBook()`, to jump back to the
    /// exact chapter + scroll fraction the user left off at. Runs on the
    /// next runloop tick so Auto Layout has already sized `scrollView`.
    func restoreReadingProgressIfNeeded() {
        guard !document.hasRestoredInitialPosition else { return }
        document.hasRestoredInitialPosition = true
        guard let entry = ReaderProgressStore.read(bookId: document.book.id) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreReadingAnchor(
                ReadingAnchor(offsetFraction: CGFloat(entry.offsetFraction), characterOffset: entry.characterOffset)
            )
            self.send(.updatePageIndicator)
        }
    }

}
#endif
