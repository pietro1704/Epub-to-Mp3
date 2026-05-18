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
struct AttributedPageView: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.attributedText != attributed {
            uiView.attributedText = attributed
        }
    }
}
#elseif canImport(AppKit)
struct AttributedPageView: NSViewRepresentable {
    let attributed: NSAttributedString

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
        tv.textStorage?.setAttributedString(attributed)
    }
}
#endif
