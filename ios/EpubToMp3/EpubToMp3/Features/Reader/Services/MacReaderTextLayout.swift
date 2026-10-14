#if os(macOS) && !targetEnvironment(simulator)
import AppKit

/// Sizes an AppKit reader text view to its live scroll viewport after each
/// content or geometry change. `NSTextView(frame: .zero, ...)` otherwise
/// keeps a zero-width text container and silently draws no glyphs.
@MainActor
enum MacReaderTextLayout {
    static func fit(_ textView: NSTextView, in scrollView: NSScrollView) {
        let viewport = scrollView.contentView.bounds
        guard viewport.width > 0, viewport.height > 0,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        // Width tracking can invalidate layout when the view frame changes.
        // Commit the final width before measuring any glyphs.
        textView.setFrameSize(NSSize(width: viewport.width, height: textView.frame.height))
        container.widthTracksTextView = true
        container.containerSize = NSSize(
            width: max(1, viewport.width - textView.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // NSTextView's used rect can include fractional paragraph spacing
        // beyond the last visible glyph. Base the scroll extent on its actual
        // document-space bottom so chapter-end navigation and clipping checks
        // agree on the same final geometry.
        let height = max(viewport.height, ceil(used.maxY + textView.textContainerInset.height))
        textView.setFrameOrigin(.zero)
        textView.setFrameSize(NSSize(width: viewport.width, height: height))
    }
}
#endif
