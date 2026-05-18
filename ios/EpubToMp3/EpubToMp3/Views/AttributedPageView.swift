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
/// Internal UIView wrapper — uses GeometryReader to learn its real size
/// from SwiftUI, then forces both the textContainer width AND the view
/// frame to match. Without the frame pin, UITextView quietly extends
/// past its parent on iPhone SE.
struct AttributedPageView: View {
    let attributed: NSAttributedString
    let width: CGFloat

    var body: some View {
        // Measure the *actual* SwiftUI bounds and pass them to the
        // UITextView. The previous `width:` argument propagated through
        // `.frame(width:)`, but UIViewRepresentable's auto-layout pass
        // sometimes ignores it and lets the inner UITextView take its
        // intrinsic content width — which on iPhone SE meant lines
        // extended ~16pt past the right margin. Going through
        // GeometryReader pins both the textContainer and the view frame
        // to the same number.
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: geo.size
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
private final class FixedWidthTextView: UITextView {
    var pinnedWidth: CGFloat = 320

    override var intrinsicContentSize: CGSize {
        let height = sizeThatFits(
            CGSize(width: pinnedWidth, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: pinnedWidth, height: ceil(height))
    }
}

private struct _AttributedPageRep: UIViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize

    func makeUIView(context: Context) -> FixedWidthTextView {
        let tv = FixedWidthTextView(frame: CGRect(origin: .zero, size: size))
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        // Resist SwiftUI's attempts to stretch us horizontally.
        tv.setContentHuggingPriority(.required, for: .horizontal)
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: FixedWidthTextView, context: Context) {
        uiView.pinnedWidth = size.width
        uiView.textContainer.size = CGSize(
            width: size.width,
            height: .greatestFiniteMagnitude
        )
        if uiView.attributedText != attributed {
            uiView.attributedText = attributed
        }
        uiView.invalidateIntrinsicContentSize()
    }
}
#elseif canImport(AppKit)
struct AttributedPageView: View {
    let attributed: NSAttributedString
    let width: CGFloat

    var body: some View {
        GeometryReader { geo in
            _AttributedPageRep(
                attributed: attributed,
                size: CGSize(width: max(80, width), height: geo.size.height)
            )
            .frame(width: max(80, width), height: geo.size.height, alignment: .topLeading)
        }
    }
}

private struct _AttributedPageRep: NSViewRepresentable {
    let attributed: NSAttributedString
    let size: CGSize

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
