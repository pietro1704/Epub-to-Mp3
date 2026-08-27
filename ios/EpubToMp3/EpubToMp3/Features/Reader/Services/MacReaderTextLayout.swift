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

        container.containerSize = NSSize(
            width: viewport.width,
            height: .greatestFiniteMagnitude
        )
        container.widthTracksTextView = true
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = max(
            viewport.height,
            ceil(used.height + textView.textContainerInset.height * 2)
        )
        textView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: height)
    }
}
#endif
