import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders a single paginated page (`NSAttributedString` slice) using the
/// same TextKit stack that `Paginator.paginateAttributed` used to compute
/// the page boundary. This guarantees pixel-perfect alignment between
/// "what fits" (the paginator's view) and "what is drawn" (the user's
/// view) — SwiftUI's `Text(AttributedString:)` silently drops a handful
/// of paragraph-style attributes (most notably `paragraphSpacingBefore`),
/// which makes the rendered page visually shorter than the slice the
/// paginator put into it.
///
/// The view is non-scrolling, non-editable, and fully transparent so the
/// reader's theme background shows through. Selection is enabled because
/// readers expect to long-press for copy / look-up.
#if canImport(UIKit)
struct AttributedPageView: View {
    let attributed: NSAttributedString
    let width: CGFloat
    var scrollable: Bool = false
    var onLinkTap: ((URL) -> Bool)? = nil
    /// Non-link tap in one of the three horizontal zones. Paginated
    /// mode forwards this to `advancePage` / `retreatPage` /
    /// `onCenterTap`; scroll mode collapses every zone into a
    /// chrome-toggle.
    var onZoneTap: ((ReaderTapZone) -> Void)? = nil
    /// Horizontal swipe. Paginated mode uses this for swipe-to-turn;
    /// scroll mode ignores it (the scroll view absorbs horizontal
    /// scrolls into its own pan).
    var onSwipe: ((ReaderSwipeDirection) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: geo.size,
                scrollable: scrollable,
                onLinkTap: onLinkTap,
                onZoneTap: onZoneTap,
                onSwipe: onSwipe
            )
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: max(80, width))
    }
}

/// Subclass overrides `intrinsicContentSize` so SwiftUI's auto-layout
/// pass treats the view as if it has the exact `(width, computed-height)`
/// it should occupy. Without this, the standard UITextView reports an
/// intrinsic size that lets SwiftUI extend it past the parent column.
///
/// Also overrides `point(inside:with:)` so taps only land on this view
/// when they hit an actual `.link` attribute — every other tap passes
/// through to the SwiftUI layer below (chrome toggle, page-turn zones,
/// scroll gesture). User spec: "toque em meio da tela deve seguir
/// hiperlinks, com maior precedencia. somente se sem hiperlinks ...".
/// Zone the user tapped, classified by horizontal position. The reader
/// uses this for the Apple Books-style tap partition: left = previous
/// page, center = toggle chrome, right = next page.
enum ReaderTapZone { case left, center, right }
/// Swipe direction reported by the in-view pan recognizer.
enum ReaderSwipeDirection { case left, right }

private final class FixedWidthTextView: UITextView, UIGestureRecognizerDelegate {
    var pinnedWidth: CGFloat = 320
    /// `true` = consume every touch (paginated mode owns the gesture
    /// pipeline end-to-end); `false` = let only tap-on-link consume
    /// (scroll mode also lets UITextView's internal pan handle scroll).
    var consumeAllTouches: Bool = false
    /// Called for a tap that did NOT land on a `.link` glyph. Receives
    /// the zone the tap landed in (left third, center third, right
    /// third). Used for page-turn + chrome-toggle without a SwiftUI
    /// overlay sitting between the user and the link layer.
    var onZoneTap: ((ReaderTapZone) -> Void)?
    /// Called for a horizontal swipe — page-turn shortcut.
    var onSwipe: ((ReaderSwipeDirection) -> Void)?

    override var intrinsicContentSize: CGSize {
        let height = sizeThatFits(
            CGSize(width: pinnedWidth, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: pinnedWidth, height: ceil(height))
    }

    /// Add the tap + swipe recognizers exactly once.
    func installReaderGestures() {
        guard gestureRecognizers?.contains(where: { $0.name == "reader.tap" }) != true else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tap.name = "reader.tap"
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)

        for (selector, direction): (Selector, UISwipeGestureRecognizer.Direction) in [
            (#selector(handleReaderSwipeLeft(_:)), .left),
            (#selector(handleReaderSwipeRight(_:)), .right),
        ] {
            let swipe = UISwipeGestureRecognizer(target: self, action: selector)
            swipe.direction = direction
            swipe.name = "reader.swipe.\(direction == .left ? "left" : "right")"
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }

    @objc private func handleReaderTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        // Link precedence: if the tap landed on a `.link` glyph, let
        // UITextView's own link-interaction recognizers (already
        // installed by the framework) handle it. We bail out here so
        // the zone callback doesn't double-fire.
        if linkURL(at: point) != nil { return }
        let zone = classifyZone(x: point.x, in: bounds.width)
        onZoneTap?(zone)
    }

    @objc private func handleReaderSwipeLeft(_ swipe: UISwipeGestureRecognizer) {
        onSwipe?(.left)
    }
    @objc private func handleReaderSwipeRight(_ swipe: UISwipeGestureRecognizer) {
        onSwipe?(.right)
    }

    private func classifyZone(x: CGFloat, in width: CGFloat) -> ReaderTapZone {
        guard width > 0 else { return .center }
        let third = width / 3
        if x < third { return .left }
        if x > width - third { return .right }
        return .center
    }

    /// Returns the `.link` URL at the given point in this view's
    /// coordinate space, or `nil` if no link sits there.
    func linkURL(at point: CGPoint) -> URL? {
        guard let attributedText, attributedText.length > 0 else { return nil }
        let inset = textContainerInset
        let p = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let glyphIndex = layoutManager.glyphIndex(
            for: p, in: textContainer, fractionOfDistanceThroughGlyph: nil
        )
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard rect.contains(p) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < attributedText.length else { return nil }
        return attributedText.attributes(at: charIndex, effectiveRange: nil)[.link] as? URL
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Let our reader tap / swipe run alongside UITextView's built-in
    /// link + selection recognizers. `cancelsTouchesInView = false`
    /// already lets the touches reach the framework recognizers; this
    /// confirms simultaneous recognition.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    // MARK: - Touch filtering for the scroll-mode case

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !consumeAllTouches else { return super.point(inside: point, with: event) }
        // Legacy link-only filter retained as fallback for future call
        // sites that want it. Paginated + scroll both flip
        // `consumeAllTouches` on now, so this branch is currently dead
        // code in practice.
        return linkURL(at: point) != nil
    }
}

private struct _AttributedPageRep: UIViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize
    let scrollable: Bool
    let onLinkTap: ((URL) -> Bool)?
    let onZoneTap: ((ReaderTapZone) -> Void)?
    let onSwipe: ((ReaderSwipeDirection) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTap: ((URL) -> Bool)?
        init(onLinkTap: ((URL) -> Bool)?) { self.onLinkTap = onLinkTap }
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if onLinkTap?(url) == true { return false }
            return true
        }
    }

    func makeUIView(context: Context) -> FixedWidthTextView {
        let tv = FixedWidthTextView(frame: CGRect(origin: .zero, size: size))
        tv.isEditable = false
        tv.isScrollEnabled = scrollable
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        tv.delegate = context.coordinator
        tv.setContentHuggingPriority(.required, for: .horizontal)
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .vertical)
        if scrollable {
            tv.showsVerticalScrollIndicator = true
            tv.alwaysBounceVertical = true
        }
        tv.installReaderGestures()
        return tv
    }

    func updateUIView(_ uiView: FixedWidthTextView, context: Context) {
        context.coordinator.onLinkTap = onLinkTap
        uiView.pinnedWidth = size.width
        uiView.isScrollEnabled = scrollable
        // Both modes consume every touch now: the view itself does the
        // link / zone / swipe classification internally. SwiftUI no
        // longer sits between the user and the text content.
        uiView.consumeAllTouches = true
        uiView.onZoneTap = onZoneTap
        uiView.onSwipe = onSwipe
        uiView.textContainer.size = CGSize(
            width: size.width,
            height: scrollable ? .greatestFiniteMagnitude : size.height
        )
        uiView.attributedText = attributed
        uiView.invalidateIntrinsicContentSize()
    }
}
#elseif canImport(AppKit)
struct AttributedPageView: View {
    let attributed: NSAttributedString
    let width: CGFloat
    var scrollable: Bool = false

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: CGSize(width: max(80, width), height: geo.size.height),
                scrollable: scrollable
            )
            .frame(width: max(80, width), height: geo.size.height, alignment: .topLeading)
        }
    }
}

private struct _AttributedPageRep: NSViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize
    let scrollable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainer?.lineFragmentPadding = 0
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textContainer?.size = NSSize(width: size.width, height: size.height)
        tv.textStorage?.setAttributedString(attributed)
    }
}
#endif
