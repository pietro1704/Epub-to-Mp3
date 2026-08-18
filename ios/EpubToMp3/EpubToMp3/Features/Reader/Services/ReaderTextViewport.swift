#if os(iOS)
import UIKit

/// Applies the final TextKit presentation for one committed reader viewport.
/// Transition ordering and raw-offset restoration stay outside this module.
@MainActor
final class ReaderTextViewport {
    struct Facts {
        let layoutResult: ReaderPaginatedTextLayout.Result?
        let canonicalPageOffsets: [CGFloat]
        let requiresScrollingFallback: Bool
        let contentHeight: CGFloat
        let trailingInset: CGFloat
    }

    private let textView: UITextView
    private let scrollView: UIScrollView
    private let hostView: UIView
    private let pageIndicator: UILabel
    private let overflowGuard: UIView
    private let underflowGuard: UIView
    private let paginatedHeight: NSLayoutConstraint
    private let scrollingHeight: NSLayoutConstraint

    private(set) var facts = Facts(layoutResult: nil, canonicalPageOffsets: [0], requiresScrollingFallback: false, contentHeight: 0, trailingInset: 0)

    init(
        textView: UITextView,
        scrollView: UIScrollView,
        hostView: UIView,
        pageIndicator: UILabel,
        overflowGuard: UIView,
        underflowGuard: UIView,
        paginatedHeight: NSLayoutConstraint,
        scrollingHeight: NSLayoutConstraint
    ) {
        self.textView = textView
        self.scrollView = scrollView
        self.hostView = hostView
        self.pageIndicator = pageIndicator
        self.overflowGuard = overflowGuard
        self.underflowGuard = underflowGuard
        self.paginatedHeight = paginatedHeight
        self.scrollingHeight = scrollingHeight
    }

    func resetForChapter() {
        facts = Facts(layoutResult: nil, canonicalPageOffsets: [0], requiresScrollingFallback: false, contentHeight: 0, trailingInset: 0)
    }

    @discardableResult
    func presentPaginated(preservingRawOffset rawOffset: CGFloat?) -> Facts? {
        guard !textView.isHidden else { return nil }
        let horizontalInset = textView.textContainerInset.left + textView.textContainerInset.right
        let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
        let textWidth = textView.bounds.width - horizontalInset
        let pageHeight = scrollView.bounds.height
        guard textWidth > 1, pageHeight > verticalInset + 1 else {
            paginatedHeight.constant = max(paginatedHeight.constant, 320)
            return nil
        }
        textView.textContainer.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage.length), actualCharacterRange: nil)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let result = ReaderPaginatedTextLayout.layout(.init(
            layoutManager: textView.layoutManager,
            textContainer: textView.textContainer,
            topInset: textView.textContainerInset.top,
            bottomInset: textView.textContainerInset.bottom,
            pageHeight: pageHeight
        ))
        guard !result.requiresScrollingFallback else {
            facts = Facts(layoutResult: nil, canonicalPageOffsets: [0], requiresScrollingFallback: true, contentHeight: 0, trailingInset: 0)
            return facts
        }
        let contentHeight = result.contentHeight
        let naturalScrollableHeight = max(0, contentHeight - pageHeight)
        let trailingInset = rawOffset.map { max(0, $0 - naturalScrollableHeight) } ?? 0
        scrollView.contentInset.bottom = trailingInset
        paginatedHeight.constant = contentHeight
        textView.contentSize.height = contentHeight
        facts = Facts(
            layoutResult: result,
            canonicalPageOffsets: result.canonicalPageOffsets,
            requiresScrollingFallback: false,
            contentHeight: contentHeight,
            trailingInset: trailingInset
        )
        return facts
    }

    @discardableResult
    func presentScrolling() -> Facts? {
        guard !textView.isHidden else { return nil }
        let horizontalInset = textView.textContainerInset.left + textView.textContainerInset.right
        let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
        let textWidth = textView.bounds.width - horizontalInset
        let viewportHeight = scrollView.bounds.height
        guard textWidth > 1, viewportHeight > 1 else { return nil }
        textView.textContainer.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage.length), actualCharacterRange: nil)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let measuredHeight = max(viewportHeight, ceil(textView.layoutManager.usedRect(for: textView.textContainer).height) + verticalInset)
        // A paginated chrome transition can reserve trailing space to keep an
        // exact raw offset valid. Scrolling owns its full natural extent, so
        // carrying that reservation across modes would create a phantom gap.
        scrollView.contentInset.bottom = 0
        scrollingHeight.constant = measuredHeight
        textView.contentSize = CGSize(width: max(textView.bounds.width, 1), height: measuredHeight)
        facts = Facts(layoutResult: nil, canonicalPageOffsets: [0], requiresScrollingFallback: false, contentHeight: measuredHeight, trailingInset: 0)
        return facts
    }

    func pageNumber(at offset: CGFloat) -> Int {
        let offsets = facts.canonicalPageOffsets
        guard offsets.count > 1 else { return 1 }
        let index = facts.layoutResult?.pageIndex(at: offset)
            ?? offsets.lastIndex(where: { $0 <= offset + 0.5 }) ?? 0
        return index + 1
    }

    func pageOffset(for page: Int) -> CGFloat {
        if let result = facts.layoutResult { return result.pageOffset(for: page - 1) }
        let offsets = facts.canonicalPageOffsets
        return offsets[min(max(0, page - 1), max(0, offsets.count - 1))]
    }

    func updateIndicator(testPage: Int?) {
        let total = max(1, facts.canonicalPageOffsets.count)
        let page = min(total, max(1, testPage ?? pageNumber(at: scrollView.contentOffset.y)))
        let value = L10n.string("reader.pageOf", page, total)
        if pageIndicator.text != value { pageIndicator.text = value }
        pageIndicator.accessibilityValue = value
    }

    func updateMasks(background: UIColor, paginated: Bool) {
        guard paginated, !textView.isHidden, scrollView.bounds.height > 0 else {
            overflowGuard.isHidden = true
            underflowGuard.isHidden = true
            return
        }
        let viewport = scrollView.convert(scrollView.bounds, to: hostView)
        let offset = scrollView.contentOffset.y
        applyMask(overflowGuard, range: facts.layoutResult?.bottomOverflowMaskRange(at: offset), viewport: viewport, masksTop: false, background: background)
        applyMask(underflowGuard, range: facts.layoutResult?.topOverflowMaskRange(at: offset), viewport: viewport, masksTop: true, background: background)
        hostView.bringSubviewToFront(pageIndicator)
    }

    private func applyMask(_ mask: UIView, range: ClosedRange<CGFloat>?, viewport: CGRect, masksTop: Bool, background: UIColor) {
        guard let range else { mask.isHidden = true; return }
        let boundary = textView.convert(CGPoint(x: textView.bounds.minX, y: masksTop ? range.upperBound : range.lowerBound), to: hostView).y
        guard boundary > viewport.minY + 0.5, boundary < viewport.maxY - 0.5 else { mask.isHidden = true; return }
        mask.backgroundColor = background
        mask.frame = CGRect(x: viewport.minX, y: masksTop ? viewport.minY : boundary, width: viewport.width, height: masksTop ? boundary - viewport.minY : viewport.maxY - boundary).integral
        mask.isHidden = false
    }
}
#endif
