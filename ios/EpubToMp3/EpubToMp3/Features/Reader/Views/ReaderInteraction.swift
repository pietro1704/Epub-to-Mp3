#if os(iOS)
import UIKit

/// Serializes page/chapter input against final viewport readiness. Animations
/// are delegated to ReaderPageNavigation and glyph boundaries to the viewport.
@MainActor
final class ReaderInteraction: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let textPresentation: ReaderTextPresentation
    private let readingPosition: ReaderReadingPosition
    private let pageNavigation: ReaderPageNavigation
    private let isLoadingContent: () -> Bool
    private let isDeferringReaderGestures: () -> Bool
    private let toggleChromeVisibility: () -> Void
    private let refreshProbe: () -> Void
    private var scrollView: UIScrollView { composition.scrollView }

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         textPresentation: ReaderTextPresentation, readingPosition: ReaderReadingPosition,
         pageNavigation: ReaderPageNavigation, isLoadingContent: @escaping () -> Bool,
         isDeferringReaderGestures: @escaping () -> Bool,
         toggleChromeVisibility: @escaping () -> Void, refreshProbe: @escaping () -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.textPresentation = textPresentation
        self.readingPosition = readingPosition
        self.pageNavigation = pageNavigation
        self.isLoadingContent = isLoadingContent
        self.isDeferringReaderGestures = isDeferringReaderGestures
        self.toggleChromeVisibility = toggleChromeVisibility
        self.refreshProbe = refreshProbe
        super.init()
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, snaps a scroll destination to the nearest
    /// TextKit line-aligned page boundary. `.scrolling` mode is untouched.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard canNavigateReader, settings.readerLayout == .paginated else { return }
        if abs(velocity.x) > 0.25 {
            // Horizontal page swipes must use the same chapter-aware state
            // machine as edge taps. Without this, UIScrollView consumes the
            // gesture while the reader remains parked on the last page.
            targetContentOffset.pointee = scrollView.contentOffset
            let forward = velocity.x < 0
            DispatchQueue.main.async { [weak self] in
                self?.navigatePage(forward: forward)
            }
            return
        }
        targetContentOffset.pointee.y = pageOffset(for: pageNumber(at: targetContentOffset.pointee.y))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        textPresentation.updatePageIndicator()
        readingPosition.persistReadingProgress()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            textPresentation.updatePageIndicator()
            readingPosition.persistReadingProgress()
        }
    }

    private func pageNumber(at offset: CGFloat) -> Int {
        composition.textViewport.pageNumber(at: offset)
    }

    private func pageOffset(for page: Int) -> CGFloat {
        composition.textViewport.pageOffset(for: page)
    }

    func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              composition.loadingContainer.isHidden,
              !isDeferringReaderGestures() else { return }
        let pointInView = gesture.location(in: composition.view)
        switch ReaderTapAction.resolve(
            point: pointInView,
            in: composition.view.bounds,
            isPaginated: textPresentation.isPaginatedMode
        ) {
        case .toggleChrome:
            toggleChromeVisibility()
        case let .turnPage(forward):
            navigatePage(forward: forward)
        case .none:
            return
        }
    }

    func turnPageLeft() { turnPage(forward: false) }
    func turnPageRight() { turnPage(forward: true) }

    func handleHorizontalSwipe(_ gesture: UIPanGestureRecognizer) {
        guard canNavigateReader, gesture.state == .ended, textPresentation.isPaginatedMode else { return }
        let translation = gesture.translation(in: scrollView)
        guard abs(translation.x) > 40, abs(translation.x) > abs(translation.y) else { return }
        navigatePage(forward: translation.x < 0)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // UITextView installs its own single-tap recognizers for selectable
        // text. Let the reader's non-link tap reach the immersive action too;
        // long-press selection and link handling keep their native behavior.
        gestureRecognizer === composition.pageTap || otherGestureRecognizer === composition.pageTap
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // A centre tap is the reader's primary action. Waiting for UITextView
        // recognizers makes native EPUB typography swallow that tap before the
        // reader can hide chrome. Links are excluded in `shouldReceive`, and
        // text selection remains available through its long-press gesture.
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === composition.pageTap else { return true }
        let point = touch.location(in: composition.textView)
        return !isLink(at: point)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Chrome requests are latest-wins. They must be accepted while a
        // previous viewport transaction is committing, whereas page turns
        // still wait for that final geometry.
        if gestureRecognizer === composition.pageTap {
            return !isDeferringReaderGestures() && composition.loadingContainer.isHidden
        }
        guard canNavigateReader else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: composition.view)
        return textPresentation.isPaginatedMode && abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 20
    }

    private func isLink(at point: CGPoint) -> Bool {
        guard composition.textView.bounds.contains(point), let attributed = composition.textView.attributedText,
              attributed.length > 0 else { return false }
        let containerPoint = CGPoint(
            x: point.x - composition.textView.textContainerInset.left,
            y: point.y - composition.textView.textContainerInset.top
        )
        let glyph = composition.textView.layoutManager.glyphIndex(
            for: containerPoint,
            in: composition.textView.textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < composition.textView.layoutManager.numberOfGlyphs else { return false }
        let glyphRange = NSRange(location: glyph, length: 1)
        guard composition.textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: composition.textView.textContainer
        ).contains(containerPoint) else { return false }
        let character = composition.textView.layoutManager.characterIndexForGlyph(at: glyph)
        guard character < attributed.length else { return false }
        return attributed.attribute(.link, at: character, effectiveRange: nil) != nil
    }

    private var canNavigateReader: Bool {
        document.fulltext != nil && BookOpenScreenController.allowsReaderNavigation(
            isDeferringReaderGestures: isDeferringReaderGestures(),
            isLoadingOverlayHidden: composition.loadingContainer.isHidden,
            isViewportTransitioning: readingPosition.isViewportTransitioning
        )
    }

    private var measuredPageCount: Int {
        max(1, textPresentation.paginatedLayoutResult?.canonicalPageOffsets.count ?? textPresentation.paginatedPageOffsets.count)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        readingPosition.playback.publish(facts: .init(chromeHidden: textPresentation.chromeHidden,
            isPaginated: textPresentation.isPaginatedMode, isLoading: isLoadingContent(), layoutResult: textPresentation.paginatedLayoutResult),
            isViewportTransitioning: readingPosition.isViewportTransitioning)
        if textPresentation.isPaginatedMode {
            textPresentation.updatePageIndicator()
            textPresentation.updatePageOverflowGuard()
        }
        guard ProcessInfo.processInfo.arguments.contains("-uiTestReaderLayout") else { return }
        let offset = scrollView === composition.textView ? composition.textView.contentOffset.y : scrollView.contentOffset.y
        composition.textView.accessibilityValue = "offset=\(Int(offset.rounded()))"
        composition.scrollProbeLabel.text = "offset=\(Int(offset.rounded()))"
        refreshProbe()
    }

    private func turnPage(forward: Bool) {
        navigatePage(forward: forward)
    }

    func swipeChapterForward(_ gesture: UISwipeGestureRecognizer) {
        guard canNavigateReader, gesture.state == .ended, !textPresentation.isPaginatedMode else { return }
        navigateScrollChapter(forward: true)
    }

    func swipeChapterBackward(_ gesture: UISwipeGestureRecognizer) {
        guard canNavigateReader, gesture.state == .ended, !textPresentation.isPaginatedMode else { return }
        navigateScrollChapter(forward: false)
    }

    func uiTestPreviousChapter() {
        navigateScrollChapter(forward: false)
    }

    func uiTestNextChapter() {
        navigateScrollChapter(forward: true)
    }

    private func navigateScrollChapter(forward: Bool) {
        guard canNavigateReader else { return }
        let next = forward
            ? min(document.selectedChapter + 1, max(0, (document.fulltext?.chapters.count ?? 1) - 1))
            : max(0, document.selectedChapter - 1)
        guard next != document.selectedChapter else { return }
        readingPosition.persistReadingProgress()
        document.selectedChapter = next
        textPresentation.showChapter(document.selectedChapter)
        scrollView.setContentOffset(.zero, animated: false)
    }

    func navigatePage(forward: Bool) {
        guard canNavigateReader else { return }

        guard let fulltext = document.fulltext, fulltext.chapters[safe: document.selectedChapter] != nil else { return }
        guard pageNavigation.begin() else { return }
        composition.view.layoutIfNeeded()
        let estimatedTotal = measuredPageCount
        let current = composition.textViewport.pageNumber(at: scrollView.contentOffset.y)
        let outgoingPage = settings.pageTurnStyle == .none || UIAccessibility.isReduceMotionEnabled
            || ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion")
            ? nil : pageNavigation.snapshotReaderPage(afterScreenUpdates: false)
        if forward, current >= estimatedTotal, document.selectedChapter + 1 < fulltext.chapters.count {
            readingPosition.persistReadingProgress(); document.selectedChapter += 1; textPresentation.showChapter(document.selectedChapter)
            composition.view.layoutIfNeeded()
            pageNavigation.setPageOffset(.zero, forward: true, outgoingPage: outgoingPage)
            textPresentation.updatePageIndicator(); return
        }
        if !forward, current <= 1, document.selectedChapter > 0 {
            readingPosition.persistReadingProgress(); document.selectedChapter -= 1; textPresentation.showChapter(document.selectedChapter)
            // Chapter rendering resets viewport facts and defers pagination.
            // Resolve the destination chapter before reading its final page.
            composition.view.layoutIfNeeded()
            let previousTotal = measuredPageCount
            if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
                textPresentation.uiTestPageNumber = previousTotal
            }
            pageNavigation.setPageOffset(CGPoint(x: 0, y: pageOffset(for: previousTotal)), forward: false, outgoingPage: outgoingPage)
            textPresentation.updatePageIndicator(); return
        }
        if (forward && current >= estimatedTotal) || (!forward && current <= 1) {
            pageNavigation.settle()
            return
        }
        let next = min(estimatedTotal, max(1, current + (forward ? 1 : -1)))
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            textPresentation.uiTestPageNumber = next
        }
        pageNavigation.setPageOffset(CGPoint(x: 0, y: pageOffset(for: next)), forward: forward, outgoingPage: outgoingPage)
        textPresentation.updatePageIndicator(); readingPosition.persistReadingProgress()
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
