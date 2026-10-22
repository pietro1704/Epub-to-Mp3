#if os(iOS)
import UIKit

/// Accessibility probes report final runtime glyph geometry for reader tests.
@MainActor
final class ReaderDiagnosticsPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private var flickerStaleCount = 0
    private var flickerSpuriousCount = 0
    private var flickerEmptyCount = 0

    init(document: ReaderBookDocument, composition: ReaderViewComposition) {
        self.document = document
        self.composition = composition
    }

    func resetFlickerProbe() {
        flickerStaleCount = 0
        flickerSpuriousCount = 0
        flickerEmptyCount = 0
        updateFlickerProbe()
    }

    func updateFlickerProbe() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe") else { return }
        let chapterCount = document.fulltext?.chapters.count ?? 0
        composition.flickerChapterLabel.text = "\(document.selectedChapter)/\(chapterCount)"
        composition.flickerSummaryLabel.text = "stale=\(flickerStaleCount) spurious=\(flickerSpuriousCount) empty=\(flickerEmptyCount)"
    }

    /// Exposes visual pagination facts only in XCTest builds. UI tests need
    /// real glyph positions rather than the outer UITextView frame: the latter
    /// remains safely placed even when a sibling navigation bar overlaps text.
    func updatePaginationProbe(layoutResult paginatedLayoutResult: ReaderPaginatedTextLayout.Result?,
                               pageOffsets paginatedPageOffsets: [CGFloat], chromeHidden: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestPaginationProbe"),
              let window = composition.view.window,
              composition.textView.attributedText.length > 0,
              composition.textView.layoutManager.numberOfGlyphs > 0 else { return }

        let glyphRange = composition.textView.layoutManager.glyphRange(for: composition.textView.textContainer)
        guard glyphRange.length > 0 else { return }
        let layoutResult = paginatedLayoutResult
        let protectedFragments = layoutResult?.protectedFragments ?? []
        var completeFragmentRects: [CGRect] = []
        let clippedLineCount: Int
        if let layoutResult {
            let report = layoutResult.clippingReport(at: composition.scrollView.contentOffset.y)
            let bottomMaskedRange = layoutResult.bottomOverflowMaskRange(at: composition.scrollView.contentOffset.y)
            let topMaskedRange = layoutResult.topOverflowMaskRange(at: composition.scrollView.contentOffset.y)
            clippedLineCount = report.clippedFragments.filter { fragment in
                let bottomMasked = bottomMaskedRange.map {
                    !composition.pageOverflowGuard.isHidden && fragment.contentRect.minY >= $0.lowerBound - 0.5
                } ?? false
                let topMasked = topMaskedRange.map {
                    !composition.pageUnderflowGuard.isHidden && fragment.contentRect.maxY <= $0.upperBound + 0.5
                } ?? false
                return !bottomMasked && !topMasked
            }.count
            completeFragmentRects = report.intersectingFragments
                .filter { !report.clippedFragments.contains($0) }
                .map(\.contentRect)
        } else {
            clippedLineCount = 0
            completeFragmentRects = protectedFragments.map(\.contentRect)
        }
        let inset = composition.textView.textContainerInset
        let firstGlyph = glyphRange.location
        let lastGlyph = NSMaxRange(glyphRange) - 1
        let firstRect = composition.textView.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: firstGlyph, length: 1),
            in: composition.textView.textContainer
        )
        let lastRect = composition.textView.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: lastGlyph, length: 1),
            in: composition.textView.textContainer
        )
        let firstPoint = composition.textView.convert(
            CGPoint(x: firstRect.minX + inset.left, y: firstRect.minY + inset.top),
            to: window
        )
        let lastPoint = composition.textView.convert(
            CGPoint(x: lastRect.maxX + inset.left, y: lastRect.maxY + inset.top),
            to: window
        )
        let firstCompleteY = completeFragmentRects.first.map {
            composition.textView.convert(CGPoint(x: $0.minX + inset.left, y: $0.minY), to: window).y
        }
        let lastCompleteY = completeFragmentRects.last.map {
            composition.textView.convert(CGPoint(x: $0.maxX + inset.left, y: $0.maxY), to: window).y
        }
        let safeTop = composition.view.convert(
            CGPoint(x: 0, y: composition.view.safeAreaLayoutGuide.layoutFrame.minY),
            to: window
        ).y
        let safeBottom = composition.view.convert(
            CGPoint(x: 0, y: composition.view.safeAreaLayoutGuide.layoutFrame.maxY),
            to: window
        ).y
        let viewportTop = composition.scrollView.convert(composition.scrollView.bounds.origin, to: window).y
        let viewportBottom = composition.scrollView.convert(
            CGPoint(x: composition.scrollView.bounds.minX, y: composition.scrollView.bounds.maxY),
            to: window
        ).y
        composition.paginationProbeLabel.text = [
            "first=\(composition.textView.layoutManager.characterIndexForGlyph(at: firstGlyph))",
            "last=\(composition.textView.layoutManager.characterIndexForGlyph(at: lastGlyph))",
            "firstY=\(Int(firstPoint.y.rounded()))",
            "lastY=\(Int(lastPoint.y.rounded()))",
            "firstCompleteY=\(Int((firstCompleteY ?? firstPoint.y).rounded()))",
            "lastCompleteY=\(Int((lastCompleteY ?? lastPoint.y).rounded()))",
            "safeTop=\(Int(safeTop.rounded()))",
            "safeBottom=\(Int(safeBottom.rounded()))",
            "viewportTop=\(Int(viewportTop.rounded()))",
            "viewportBottom=\(Int(viewportBottom.rounded()))",
            "offset=\(Int(composition.scrollView.contentOffset.y.rounded()))",
            "page=\(composition.textViewport.pageNumber(at: composition.scrollView.contentOffset.y))",
            "total=\(paginatedLayoutResult?.canonicalPageOffsets.count ?? paginatedPageOffsets.count)",
            "textFrameHeight=\(Int(composition.textView.bounds.height.rounded()))",
            "measuredTextHeight=\(Int(composition.paginatedTextHeightConstraint.constant.rounded()))",
            "viewportHeight=\(Int(composition.scrollView.bounds.height.rounded()))",
            "clippedLineCount=\(clippedLineCount)",
            "chromeHidden=\(chromeHidden ? 1 : 0)",
            "paginatedHeightActive=\(composition.paginatedTextHeightConstraint.isActive ? 1 : 0)",
            "scrollingHeightActive=\(composition.scrollingTextHeightConstraint.isActive ? 1 : 0)",
        ].joined(separator: ";")
    }

}
#endif
