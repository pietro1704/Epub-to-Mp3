#if os(iOS)
import UIKit

@MainActor
final class ReaderPlaybackPosition {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private var lastPublishedReaderPageRatio: Double?

    init(document: ReaderBookDocument, composition: ReaderViewComposition) {
        self.document = document
        self.composition = composition
    }

    func resetForChapter() { lastPublishedReaderPageRatio = 0 }

    func publish(_ anchor: ReaderReadingPosition.ReadingAnchor? = nil,
                 facts: ReaderReadingPosition.Facts, isViewportTransitioning: Bool) {
        let ratio: Double
        let textLength = composition.textView.attributedText.length
        var character = anchor?.characterOffset
        let canReadGlyphAnchor = document.hasRestoredInitialPosition && !facts.isLoading && !isViewportTransitioning
        if character == nil, canReadGlyphAnchor, facts.isPaginated,
           let fragment = facts.layoutResult?.protectedFragments.first(where: {
               $0.contentRect.minY >= composition.scrollView.contentOffset.y - 0.5
           }) {
            character = composition.textView.layoutManager.characterIndexForGlyph(at: fragment.glyphRange.location)
        }
        if character == nil, canReadGlyphAnchor, textLength > 0 {
            var visible = composition.textView.convert(composition.scrollView.bounds, from: composition.scrollView)
            visible.origin.y -= composition.textView.textContainerInset.top
            let glyphs = composition.textView.layoutManager.glyphRange(forBoundingRect: visible, in: composition.textView.textContainer)
            if glyphs.length > 0 { character = composition.textView.layoutManager.characterIndexForGlyph(at: glyphs.location) }
        }
        if let character, textLength > 0 {
            // Audio follows the first visible text, not the end of the scroll
            // range: the last page still starts before the chapter's last word.
            ratio = Double(min(max(character, 0), textLength)) / Double(textLength)
        } else if let anchor {
            ratio = Double(anchor.offsetFraction)
        } else {
            let scrollable = max(
                composition.scrollView.contentSize.height + composition.scrollView.contentInset.bottom - composition.scrollView.bounds.height,
                1
            )
            ratio = Double(min(max(composition.scrollView.contentOffset.y / scrollable, 0), 1))
        }
        guard ratio.isFinite else { return }
        if let previous = lastPublishedReaderPageRatio,
           abs(previous - ratio) < 0.001 {
            return
        }
        lastPublishedReaderPageRatio = ratio
        UserDefaults.standard.set(ratio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
    }

}
#endif
