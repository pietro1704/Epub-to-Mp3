#if os(macOS) && !targetEnvironment(simulator)
import AppKit

final class MacReaderSurfaceView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onPageTap: ((Bool) -> Bool)?
    var onAppearanceChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func keyDown(with event: NSEvent) {
        guard onKeyDown?(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let forward = location.x >= bounds.midX
        if onPageTap?(forward) != true { super.mouseUp(with: event) }
    }
}

final class MacReaderTextView: NSTextView, NSTextViewDelegate {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onPageTap: ((Bool) -> Bool)?
    var onBuildSelectionMenu: ((NSRange) -> [NSMenuItem])?
    var onLinkClick: ((URL, String) -> Bool)?

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let defaultContainer = NSTextContainer(size: .zero)
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(defaultContainer)
            super.init(frame: frameRect, textContainer: defaultContainer)
        }
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) {
        guard onKeyDown?(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let characterIndex = characterIndex(at: location), shouldDeferMouseUpToTextSystem(at: characterIndex) {
            super.mouseUp(with: event)
            return
        }
        let forward = location.x >= bounds.midX
        if onPageTap?(forward) != true { super.mouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let selection = selectedRange()
        guard selection.length > 0, let extra = onBuildSelectionMenu?(selection), !extra.isEmpty else {
            return base
        }
        let menu = base ?? NSMenu()
        for (offset, item) in extra.enumerated() {
            menu.insertItem(item, at: offset)
        }
        menu.insertItem(.separator(), at: extra.count)
        return menu
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = Self.url(from: link),
              charIndex != NSNotFound,
              charIndex >= 0,
              charIndex < string.utf16.count else {
            return false
        }
        var linkRange = NSRange(location: charIndex, length: 0)
        textStorage?.attribute(.link, at: charIndex, effectiveRange: &linkRange)
        let linkText = (string as NSString).substring(with: linkRange)
        return onLinkClick?(url, linkText) ?? false
    }

    func shouldDeferMouseUpToTextSystem(at characterIndex: Int) -> Bool {
        guard characterIndex != NSNotFound,
              characterIndex >= 0,
              characterIndex < string.utf16.count else {
            return false
        }
        return textStorage?.attribute(.link, at: characterIndex, effectiveRange: nil) != nil
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let textContainerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let index = layoutManager.characterIndex(
            for: textContainerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return index == NSNotFound ? nil : index
    }

    private static func url(from link: Any) -> URL? {
        if let url = link as? URL { return url }
        if let url = link as? NSURL { return url as URL }
        if let value = link as? String { return URL(string: value) }
        return nil
    }
}

#endif
