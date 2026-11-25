#if os(macOS)
import AppKit

/// Sizes an AppKit reader text view to its live scroll viewport after each
/// content or geometry change. `NSTextView(frame: .zero, ...)` otherwise
/// keeps a zero-width text container and silently draws no glyphs.
@MainActor
enum MacReaderTextLayout {
    private static let columnGap: CGFloat = 48
    /// A narrow window shows fewer columns instead of unreadable ones.
    private static let minimumColumnWidth: CGFloat = 220

    static func fit(_ textView: NSTextView, in scrollView: NSScrollView, columns: Int = 1) {
        let viewport = scrollView.contentView.bounds
        guard viewport.width > 0, viewport.height > 0,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let usableWidth = viewport.width - textView.textContainerInset.width * 2
        let fitting = Int((usableWidth + columnGap) / (minimumColumnWidth + columnGap))
        let count = max(1, min(columns, fitting))
        if let host = textView as? MacReaderTextView {
            removeColumns(host, layoutManager: layoutManager)
            if count > 1 {
                fitColumns(count, in: host, container: container, layoutManager: layoutManager, viewport: viewport.size)
                return
            }
        }

        // Width tracking can invalidate layout when the view frame changes.
        // Commit the final width before measuring any glyphs.
        textView.setFrameSize(NSSize(width: viewport.width, height: textView.frame.height))
        container.widthTracksTextView = true
        container.containerSize = NSSize(
            width: max(1, viewport.width - textView.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        fitInlineImages(textView, container: container, viewportHeight: viewport.height)
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

    static func showsColumns(_ textView: NSTextView) -> Bool {
        (textView.layoutManager?.textContainers.count ?? 0) > 1
    }

    /// The line holding `index`, in `textView` coordinates, whichever column draws it.
    static func lineRect(forCharacterAt index: Int, in textView: NSTextView) -> NSRect? {
        guard let manager = textView.layoutManager, index >= 0, index < textView.textStorage?.length ?? 0 else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: index)
        guard let container = manager.textContainer(forGlyphAt: glyph, effectiveRange: nil),
              let host = container.textView else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: host.textContainerOrigin.x, dy: host.textContainerOrigin.y)
        return textView.convert(line, from: host)
    }

    /// The characters drawn inside `rect` (`textView` coordinates), across all columns.
    static func characterRange(in rect: NSRect, of textView: NSTextView) -> NSRange? {
        guard let manager = textView.layoutManager else { return nil }
        var result: NSRange?
        for container in manager.textContainers {
            guard let host = container.textView else { continue }
            let origin = host.textContainerOrigin
            let local = textView.convert(rect, to: host).offsetBy(dx: -origin.x, dy: -origin.y)
            let area = local.intersection(NSRect(origin: .zero, size: container.containerSize))
            guard !area.isEmpty else { continue }
            let glyphs = manager.glyphRange(forBoundingRect: area, in: container)
            guard glyphs.length > 0 else { continue }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            result = result.map { NSUnionRange($0, characters) } ?? characters
        }
        return result
    }

    private static func removeColumns(_ textView: MacReaderTextView, layoutManager: NSLayoutManager) {
        guard !textView.columnViews.isEmpty else { return }
        while layoutManager.textContainers.count > 1 {
            layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
        }
        textView.columnViews.forEach { $0.removeFromSuperview() }
        textView.columnViews = []
        textView.isVerticallyResizable = true
        textView.delegate = textView
    }

    /// Flows the chapter through linked containers: every page is one viewport
    /// tall and holds `count` columns, so page snapping stays on page starts.
    private static func fitColumns(_ count: Int, in textView: MacReaderTextView, container: NSTextContainer,
                                   layoutManager: NSLayoutManager, viewport: NSSize) {
        let inset = textView.textContainerInset
        let width = floor((viewport.width - inset.width * 2 - columnGap * CGFloat(count - 1)) / CGFloat(count))
        let size = NSSize(width: max(1, width), height: max(1, viewport.height - inset.height * 2))
        textView.isVerticallyResizable = false
        container.widthTracksTextView = false
        container.containerSize = size
        textView.setFrameOrigin(.zero)
        textView.setFrameSize(viewport)
        fitInlineImages(textView, container: container, viewportHeight: viewport.height)

        var last = container
        var pages = 1
        while true {
            layoutManager.ensureLayout(for: last)
            let glyphs = layoutManager.glyphRange(for: last)
            // An empty column means the next glyph can never fit; stop there.
            guard glyphs.length > 0, NSMaxRange(glyphs) < layoutManager.numberOfGlyphs else { break }
            let index = layoutManager.textContainers.count
            let next = NSTextContainer(size: size)
            next.widthTracksTextView = false
            layoutManager.addTextContainer(next)
            pages = index / count + 1
            let frame = NSRect(x: inset.width + CGFloat(index % count) * (size.width + columnGap),
                               y: CGFloat(index / count) * viewport.height + inset.height,
                               width: size.width, height: size.height)
            let column = textView.makeColumn(frame: frame, container: next)
            textView.addSubview(column)
            textView.columnViews.append(column)
            last = next
        }
        // Linked text views share one delegate; creating a column replaced it.
        textView.delegate = textView
        textView.setFrameSize(NSSize(width: viewport.width, height: CGFloat(pages) * viewport.height))
    }

    /// MAC-READER-IMAGE-FIT: inline EPUB figures keep their intrinsic size
    /// unless sized to the visible page, like the iOS reader does.
    private static func fitInlineImages(_ textView: NSTextView, container: NSTextContainer, viewportHeight: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let width = container.containerSize.width - container.lineFragmentPadding * 2
        let height = viewportHeight - textView.textContainerInset.height * 2
        // The shared helper resizes the stored attachments in place; only the
        // glyph layout needs to learn about it.
        guard ReaderInlineImageLayout.fitting(storage, maximumWidth: width, maximumHeight: height) != nil else { return }
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        storage.endEditing()
    }
}
#endif
