import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Zone the user tapped, classified by horizontal position. The reader
/// uses this for the Apple Books-style tap partition: left = previous
/// page, center = toggle chrome, right = next page.
///
/// Declared at file scope (outside `#if canImport(UIKit)`) so views that
/// take `(ReaderTapZone) -> Void` callbacks compile on macOS too — the
/// AppKit `AttributedPageView` variant simply ignores them.
enum ReaderTapZone { case left, center, right }
/// Swipe direction reported by the in-view pan recognizer.
enum ReaderSwipeDirection { case left, right }

/// Pure range lookup shared by scrolling and paginated TextKit readers.
enum ReaderTextHighlight {
    static func range(
        for sentenceId: String?,
        spans: [SentenceSpan],
        in attributed: NSAttributedString
    ) -> NSRange? {
        guard let sentenceId,
              let span = spans.first(where: { $0.id == sentenceId }) else { return nil }
        let text = attributed.string as NSString
        let target = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let start = min(max(0, span.startChar), text.length)
        let preferred = text.range(
            of: target,
            options: [],
            range: NSRange(location: start, length: text.length - start)
        )
        if preferred.location != NSNotFound { return preferred }
        let anywhere = text.range(of: target)
        return anywhere.location == NSNotFound ? nil : anywhere
    }
}

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
    var highlightRange: NSRange? = nil
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
    /// Reports normalized vertical scroll progress and an optional sentence id.
    var onScrollPosition: ((Double, String?) -> Void)? = nil
    var spans: [SentenceSpan] = []
    var onLongPressSentence: ((SentenceSpan, Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: geo.size,
                scrollable: scrollable,
                highlightRange: highlightRange,
                onLinkTap: onLinkTap,
                onZoneTap: onZoneTap,
                onSwipe: onSwipe,
                onScrollPosition: onScrollPosition,
                spans: spans,
                onLongPressSentence: onLongPressSentence
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
private final class FixedWidthTextView: UITextView, UIGestureRecognizerDelegate {
    var pinnedWidth: CGFloat = 320
    var spans: [SentenceSpan] = []
    var onLongPressSentence: ((SentenceSpan, Double) -> Void)?
    /// `true` = consume every touch (paginated mode owns the gesture
    /// pipeline end-to-end); `false` = let only tap-on-link consume
    /// (scroll mode also lets UITextView's internal pan handle scroll).
    var consumeAllTouches: Bool = false
    /// Scroll mode must be constrained by its SwiftUI parent so UITextView
    /// can expose a content offset; reporting the full TextKit height as an
    /// intrinsic height makes the wrapper grow to fit its content instead.
    var usesNativeScrolling: Bool = false
    /// Called for a tap that did NOT land on a `.link` glyph. Receives
    /// the zone the tap landed in (left third, center third, right
    /// third). Used for page-turn + chrome-toggle without a SwiftUI
    /// overlay sitting between the user and the link layer.
    var onZoneTap: ((ReaderTapZone) -> Void)?
    /// Called for a horizontal swipe — page-turn shortcut.
    var onSwipe: ((ReaderSwipeDirection) -> Void)?

    override var intrinsicContentSize: CGSize {
        guard !usesNativeScrolling else {
            return CGSize(width: pinnedWidth, height: UIView.noIntrinsicMetric)
        }
        let height = sizeThatFits(
            CGSize(width: pinnedWidth, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: pinnedWidth, height: ceil(height))
    }

    /// Install the reader tap recognizer and optional horizontal page-turn pan.
    /// The pan only recognizes predominantly horizontal motion, leaving the
    /// native UIScrollView pan responsible for vertical scrolling.
    func installReaderGestures(includeSwipe: Bool) {
        if gestureRecognizers?.contains(where: { $0.name == "reader.tap" }) != true {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
            tap.name = "reader.tap"
            tap.cancelsTouchesInView = false
            tap.delegate = self
            addGestureRecognizer(tap)
        }
        if includeSwipe,
           gestureRecognizers?.contains(where: { $0.name == "reader.pan" }) != true {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleReaderPan(_:)))
            pan.name = "reader.pan"
            pan.delegate = self
            // Cancel touches when a horizontal swipe is recognised so the
            // SwiftUI SpatialTapGesture overlay does not also fire and trigger
            // a second page turn for the same gesture. Long-press (word
            // selection) still works because the pan only recognises after
            // the 40 px horizontal threshold is crossed.
            pan.cancelsTouchesInView = true
            addGestureRecognizer(pan)
        }
        if gestureRecognizers?.contains(where: { $0.name == "reader.longPress" }) != true {
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleReaderLongPress(_:))
            )
            longPress.name = "reader.longPress"
            longPress.minimumPressDuration = 0.4
            longPress.cancelsTouchesInView = false
            addGestureRecognizer(longPress)
        }
    }

    @objc func handleReaderTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        // Keep the outer navigation gutters available for page/chapter
        // turns. A link glyph that happens to extend into the first/last
        // few percent of the UITextView must not swallow the reader's edge
        // tap; links in the actual text column retain precedence.
        let isNavigationGutter = point.x < bounds.width * 0.10 || point.x > bounds.width * 0.90
        if !isNavigationGutter, linkURL(at: point) != nil { return }
        let zone = classifyZone(x: point.x, in: bounds.width)
        onZoneTap?(zone)
    }

    @objc func handleReaderPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, let onSwipe else { return }
        let v = pan.velocity(in: self)
        let t = pan.translation(in: self)
        // Must be predominantly horizontal and cross a minimum threshold.
        guard abs(t.x) > 40, abs(t.x) > abs(t.y) * 1.5 else { return }
        onSwipe(v.x < 0 ? .left : .right)
    }

    @objc private func handleReaderLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !spans.isEmpty,
              let attributedText else { return }
        let point = gesture.location(in: self)
        let inset = textContainerInset
        let textPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let glyph = layoutManager.glyphIndex(
            for: textPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < layoutManager.numberOfGlyphs else { return }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyph)
        guard characterIndex < attributedText.length else { return }
        let string = attributedText.string as NSString
        let suffix = string.substring(from: characterIndex)
        guard let span = spans.first(where: { span in
            let probe = String(span.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            return !probe.isEmpty && suffix.contains(probe)
        }) else { return }
        let probe = String(span.text.prefix(40))
        let match = string.range(of: probe)
        let offset = match.location == NSNotFound
            ? 0
            : max(0, characterIndex - match.location)
        let ratio = min(1, Double(offset) / Double(max(1, span.text.count)))
        onLongPressSentence?(span, ratio)
    }

    private func classifyZone(x: CGFloat, in width: CGFloat) -> ReaderTapZone {
        guard width > 0 else { return .center }
        let third = width / 3
        if x < third { return .left }
        if x > width - third { return .right }
        return .center
    }

    /// Identity of the `NSAttributedString` last assigned to
    /// `attributedText`. SwiftUI invokes `updateUIView` on EVERY parent
    /// re-render — including chrome-toggle re-renders that don't change
    /// the slice at all. Without this guard, `attributedText = attributed`
    /// runs unconditionally and forces a full TextKit relayout, visible
    /// to the user as a 1-frame flicker the moment the chrome animation
    /// starts. The paginator returns the SAME `NSAttributedString`
    /// instance from its memo cache when the layout key matches, so an
    /// identity comparison is a true "did the page text change" check.
    var assignedAttributedIdentity: ObjectIdentifier?
    var assignedHighlightRange: NSRange?
    /// Last width pushed into the text container. Avoids re-setting the
    /// container size when nothing changed (same cause as above).
    var assignedContainerSize: CGSize = .zero

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
    let highlightRange: NSRange?
    let onLinkTap: ((URL) -> Bool)?
    let onZoneTap: ((ReaderTapZone) -> Void)?
    let onSwipe: ((ReaderSwipeDirection) -> Void)?
    let onScrollPosition: ((Double, String?) -> Void)?
    let spans: [SentenceSpan]
    let onLongPressSentence: ((SentenceSpan, Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap, onScrollPosition: onScrollPosition)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTap: ((URL) -> Bool)?
        var onScrollPosition: ((Double, String?) -> Void)?
        init(onLinkTap: ((URL) -> Bool)?, onScrollPosition: ((Double, String?) -> Void)?) {
            self.onLinkTap = onLinkTap
            self.onScrollPosition = onScrollPosition
        }
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if onLinkTap?(url) == true { return false }
            return true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.isScrollEnabled {
                let range = max(1, scrollView.contentSize.height - scrollView.bounds.height)
                let ratio = max(0, min(1, scrollView.contentOffset.y / range))
                onScrollPosition?(ratio, nil)
                return
            }
            if scrollView.contentOffset != .zero {
                scrollView.contentOffset = .zero
            }
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
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.bounces = false
        tv.alwaysBounceVertical = false
        tv.alwaysBounceHorizontal = false
        tv.delegate = context.coordinator
        tv.setContentHuggingPriority(.required, for: .horizontal)
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .vertical)
        if scrollable {
            tv.showsVerticalScrollIndicator = true
            tv.alwaysBounceVertical = true
            tv.bounces = true
        }
        return tv
    }

    func updateUIView(_ uiView: FixedWidthTextView, context: Context) {
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.onScrollPosition = onScrollPosition
        uiView.pinnedWidth = size.width
        uiView.usesNativeScrolling = scrollable
        uiView.isScrollEnabled = scrollable
        uiView.showsVerticalScrollIndicator = scrollable
        uiView.showsHorizontalScrollIndicator = false
        uiView.bounces = scrollable
        uiView.alwaysBounceVertical = scrollable
        uiView.alwaysBounceHorizontal = false
        if !scrollable {
            uiView.setContentOffset(.zero, animated: false)
        }
        uiView.consumeAllTouches = scrollable || onZoneTap != nil || onSwipe != nil
        uiView.onZoneTap = onZoneTap
        uiView.onSwipe = onSwipe
        uiView.spans = spans
        uiView.onLongPressSentence = onLongPressSentence
        uiView.installReaderGestures(includeSwipe: onSwipe != nil)

        let desiredContainer = CGSize(
            width: size.width,
            height: scrollable ? .greatestFiniteMagnitude : size.height
        )
        if uiView.assignedContainerSize != desiredContainer {
            uiView.textContainer.size = desiredContainer
            uiView.assignedContainerSize = desiredContainer
        }

        // Identity-gate the reassignment: the paginator memo returns the
        // same `NSAttributedString` instance when the layout key
        // (chapter id × pageSize × margins × font × renderVersion)
        // matches, so a chrome-toggle re-render hits this branch with
        // `attributed === uiView.assignedAttributedIdentity`'s
        // referent and skips the TextKit relayout that was visible as a
        // 1-frame flicker.
        let newIdentity = ObjectIdentifier(attributed)
        if uiView.assignedAttributedIdentity != newIdentity
            || uiView.assignedHighlightRange != highlightRange {
            let rendered = NSMutableAttributedString(attributedString: attributed)
            if let highlightRange,
               highlightRange.location >= 0,
               highlightRange.location + highlightRange.length <= rendered.length {
                rendered.addAttribute(
                    .backgroundColor,
                    value: UIColor.systemYellow.withAlphaComponent(0.45),
                    range: highlightRange
                )
            }
            uiView.attributedText = rendered
            uiView.assignedAttributedIdentity = newIdentity
            uiView.assignedHighlightRange = highlightRange
            uiView.invalidateIntrinsicContentSize()
        }
    }
}
#elseif canImport(AppKit)
struct AttributedPageView: View {
    let attributed: NSAttributedString
    let width: CGFloat
    var highlightRange: NSRange? = nil
    var scrollable: Bool = false
    // API parity with the UIKit variant — accepted but ignored on
    // macOS, where NSTextView routes link/click handling through its
    // own delegate machinery and there is no Apple-Books-style tap
    // partition on a mouse-driven surface.
    var onLinkTap: ((URL) -> Bool)? = nil
    var onZoneTap: ((ReaderTapZone) -> Void)? = nil
    var onSwipe: ((ReaderSwipeDirection) -> Void)? = nil
    var onScrollPosition: ((Double, String?) -> Void)? = nil
    var spans: [SentenceSpan] = []
    var onLongPressSentence: ((SentenceSpan, Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: CGSize(width: max(80, width), height: geo.size.height),
                scrollable: scrollable,
                highlightRange: highlightRange
            )
            .frame(width: max(80, width), height: geo.size.height, alignment: .topLeading)
        }
    }
}

private struct _AttributedPageRep: NSViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize
    let scrollable: Bool
    let highlightRange: NSRange?

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
