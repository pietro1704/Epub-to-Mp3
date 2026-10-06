#if os(iOS)
import UIKit
import XCTest

@testable import EpubToMp3

@MainActor
final class ReaderTextViewportTests: XCTestCase {
    private func makeViewport(
        height: CGFloat = 240,
        fontSize: CGFloat = 17
    ) -> (viewport: ReaderTextViewport, scrollView: UIScrollView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        let scroll = UIScrollView(frame: host.bounds)
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: height))
        let indicator = UILabel()
        let overflow = UIView()
        let underflow = UIView()
        host.addSubview(scroll)
        scroll.addSubview(text)
        host.addSubview(indicator)
        host.addSubview(overflow)
        host.addSubview(underflow)
        text.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        text.textContainer.lineFragmentPadding = 0
        text.font = .systemFont(ofSize: fontSize)
        text.attributedText = NSAttributedString(
            string: String(repeating: "A viewport sentence with enough text to wrap. ", count: 160),
            attributes: [.font: UIFont.systemFont(ofSize: fontSize)]
        )
        let paginated = text.heightAnchor.constraint(equalToConstant: 1)
        let scrolling = text.heightAnchor.constraint(equalToConstant: 1)
        return (
            ReaderTextViewport(
                textView: text,
                scrollView: scroll,
                hostView: host,
                pageIndicator: indicator,
                overflowGuard: overflow,
                underflowGuard: underflow,
                paginatedHeight: paginated,
                scrollingHeight: scrolling
            ),
            scroll
        )
    }

    func testPresentPaginatedPublishesCanonicalOffsets() {
        let (viewport, _) = makeViewport()

        let facts = viewport.presentPaginated(preservingRawOffset: nil)

        XCTAssertNotNil(facts)
        XCTAssertFalse(facts?.requiresScrollingFallback ?? true)
        XCTAssertEqual(viewport.pageOffset(for: 1), 0)
        XCTAssertGreaterThanOrEqual(viewport.pageNumber(at: 0), 1)
        for offset in facts?.canonicalPageOffsets ?? [] {
            guard let result = facts?.layoutResult else {
                return XCTFail("Paginated presentation must retain its layout result")
            }
            let report = result.clippingReport(at: offset)
            let bottomMask = result.bottomOverflowMaskRange(at: offset)
            let topMask = result.topOverflowMaskRange(at: offset)
            let unmasked = report.clippedFragments.filter { fragment in
                let bottomMasked = bottomMask.map { fragment.contentRect.minY >= $0.lowerBound - 0.5 } ?? false
                let topMasked = topMask.map { fragment.contentRect.maxY <= $0.upperBound + 0.5 } ?? false
                return !bottomMasked && !topMasked
            }
            XCTAssertTrue(unmasked.isEmpty, "Canonical page must not expose a partial protected fragment")
        }
    }

    func testOversizedProtectedFragmentRequestsScrollingFallback() {
        let (viewport, _) = makeViewport(height: 80, fontSize: 120)

        let facts = viewport.presentPaginated(preservingRawOffset: nil)

        XCTAssertTrue(facts?.requiresScrollingFallback ?? false)
    }

    func testRawOffsetReservationDoesNotChooseACanonicalPageOffset() {
        let (viewport, _) = makeViewport()

        let facts = viewport.presentPaginated(preservingRawOffset: 9_999)

        XCTAssertGreaterThan(facts?.trailingInset ?? 0, 0)
        XCTAssertNotEqual(viewport.pageOffset(for: 2), 9_999)
    }

    func testScrollingClearsAPaginatedRawOffsetReservation() {
        let (viewport, scrollView) = makeViewport()

        _ = viewport.presentPaginated(preservingRawOffset: 9_999)
        _ = viewport.presentScrolling()

        XCTAssertEqual(scrollView.contentInset.bottom, 0)
    }
}
#endif
