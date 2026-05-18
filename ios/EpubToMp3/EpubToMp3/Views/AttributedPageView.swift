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
    /// Optional handler invoked when the user taps an `.link` attribute
    /// in the rendered text. Return `true` if the host handled the link
    /// (e.g. navigated to another chapter); `false` to let iOS open the
    /// URL externally (the default UITextView behaviour for absolute
    /// URLs).
    var onLinkTap: ((URL) -> Bool)? = nil

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: geo.size,
                scrollable: scrollable,
                onLinkTap: onLinkTap
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
private final class FixedWidthTextView: UITextView {
    var pinnedWidth: CGFloat = 320
    /// When `true` (paginated mode) only tap-on-link consumes touches;
    /// every other tap falls through to the SwiftUI tap-zone layer
    /// (page-turn / chrome toggle). When `false` (scrolling mode) the
    /// text view receives ALL touches so its internal pan gesture can
    /// scroll the content — without this, the pan was being filtered
    /// out and scroll mode froze.
    var linkOnlyHitTest: Bool = false

    override var intrinsicContentSize: CGSize {
        let height = sizeThatFits(
            CGSize(width: pinnedWidth, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: pinnedWidth, height: ceil(height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard linkOnlyHitTest else {
            // Scroll mode (and any other "consume everything" mode):
            // default UITextView hit-test so pan + tap + link all work.
            return super.point(inside: point, with: event)
        }
        guard let attributedText = self.attributedText, attributedText.length > 0 else {
            return false
        }
        let inset = textContainerInset
        let p = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        let glyphIndex = layoutManager.glyphIndex(
            for: p, in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard rect.contains(p) else { return false }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < attributedText.length else { return false }
        let attrs = attributedText.attributes(at: charIndex, effectiveRange: nil)
        return attrs[.link] != nil
    }
}

private struct _AttributedPageRep: UIViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize
    let scrollable: Bool
    let onLinkTap: ((URL) -> Bool)?

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
            // Host handled the link → tell UITextView not to open it.
            if onLinkTap?(url) == true { return false }
            // Host didn't handle it → let iOS open externally (Safari /
            // mail / etc). For relative URIs with no scheme this opens
            // nothing useful, but it's the safest fallback when the
            // host hasn't wired a chapter-jump handler.
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
        return tv
    }

    func updateUIView(_ uiView: FixedWidthTextView, context: Context) {
        context.coordinator.onLinkTap = onLinkTap
        uiView.pinnedWidth = size.width
        uiView.isScrollEnabled = scrollable
        // Paginated mode wants only link-taps; scroll mode needs every
        // touch so pan-to-scroll works (link-hit-only mode would
        // freeze scrolling because non-link pans got filtered out).
        uiView.linkOnlyHitTest = !scrollable
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
