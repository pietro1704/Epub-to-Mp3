#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

@MainActor
final class MacReaderViewComposition {
    struct Actions {
        let close: Selector
        let contents: Selector
        let search: Selector
        let settings: Selector
        let retryLoading: Selector
    }
    let view: NSView
    private unowned let target: NSViewController
    private let settings: AppSettings
    private let actions: Actions
    let loading: MacReaderLoadingPresentation
    private let onLink: (URL, String) -> Bool
    private let onKeyDown: (NSEvent) -> Bool
    private let onPageTap: (Bool) -> Void
    private let onBuildSelectionMenu: (NSRange) -> [NSMenuItem]
    let chaptersTable = NSTableView()
    let textView = MacReaderTextView()
    let comicPageImageView = NSImageView()
    let contentScrollView = NSScrollView()
    let toolbar = NSStackView()
    let bookTitleLabel = NSTextField(labelWithString: "")
    let chapterTitleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let tocPopover = NSPopover()
    let settingsPopover = NSPopover()

    init(view: NSView, target: NSViewController, settings: AppSettings, actions: Actions,
         cancelJourney: @escaping () -> Void, onLink: @escaping (URL, String) -> Bool,
         onKeyDown: @escaping (NSEvent) -> Bool, onPageTap: @escaping (Bool) -> Void,
         onBuildSelectionMenu: @escaping (NSRange) -> [NSMenuItem]) {
        self.view = view
        self.target = target
        self.settings = settings
        self.actions = actions
        loading = MacReaderLoadingPresentation(cancelJourney: cancelJourney)
        self.onLink = onLink
        self.onKeyDown = onKeyDown
        self.onPageTap = onPageTap
        self.onBuildSelectionMenu = onBuildSelectionMenu
    }

    func configure() {
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.string("reader.close")) ?? NSImage(), target: target, action: actions.close)
        close.bezelStyle = .texturedRounded
        close.toolTip = L10n.string("reader.close")
        close.setAccessibilityIdentifier("reader.close")

        let toc = NSButton(title: L10n.string("reader.toc"), target: target, action: actions.contents)
        toc.bezelStyle = .texturedRounded
        toc.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: L10n.string("reader.toc"))
        toc.imagePosition = .imageLeading
        toc.toolTip = L10n.string("reader.toc")
        toc.setAccessibilityIdentifier("reader.toc.toggle")

        let search = NSButton(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.string("reader.search.placeholder")) ?? NSImage(),
            target: target, action: actions.search
        )
        search.bezelStyle = .texturedRounded
        search.toolTip = L10n.string("reader.search.placeholder")
        search.setAccessibilityIdentifier("reader.search")

        let appearance = NSButton(title: "Aa", target: target, action: actions.settings)
        appearance.bezelStyle = .texturedRounded
        appearance.font = .systemFont(ofSize: 13, weight: .semibold)
        appearance.toolTip = L10n.string("reader.settings")
        appearance.setAccessibilityLabel(L10n.string("reader.settings"))
        appearance.setAccessibilityIdentifier("reader.settings.toggle")

        bookTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bookTitleLabel.alignment = .center
        bookTitleLabel.lineBreakMode = .byTruncatingTail
        bookTitleLabel.setAccessibilityIdentifier("reader.title")
        bookTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let leadingControls = NSStackView(views: [close, toc, search, appearance])
        leadingControls.orientation = .horizontal
        leadingControls.spacing = 8
        let leadingSpacer = NSView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailingSpacer = NSView()
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(leadingControls)
        toolbar.addArrangedSubview(leadingSpacer)
        toolbar.addArrangedSubview(bookTitleLabel)
        toolbar.addArrangedSubview(trailingSpacer)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toolbar.spacing = 10
        toolbar.distribution = .fill
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.setAccessibilityIdentifier("reader.toolbar")

        chapterTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        chapterTitleLabel.lineBreakMode = .byTruncatingTail
        chapterTitleLabel.setAccessibilityIdentifier("reader.chapterTitle")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.setAccessibilityIdentifier("reader.status")
        textView.isEditable = false
        textView.isSelectable = true
        textView.onLinkClick = { [weak self] url, linkText in
            self?.onLink(url, linkText) ?? true
        }
        textView.setAccessibilityIdentifier("reader.content")
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        contentScrollView.documentView = textView
        contentScrollView.hasVerticalScroller = true
        MacReaderTheme.apply(
            settings: settings,
            surface: view,
            scrollView: contentScrollView,
            textView: textView,
            toolbar: toolbar,
            labels: [bookTitleLabel, chapterTitleLabel, statusLabel]
        )

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        chapterTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        view.addSubview(chapterTitleLabel)
        view.addSubview(statusLabel)
        view.addSubview(contentScrollView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            chapterTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            chapterTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            chapterTitleLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: chapterTitleLabel.bottomAnchor, constant: 8),
            contentScrollView.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
        ])
        loading.configure(in: view, toolbar: toolbar, target: target, retryAction: actions.retryLoading)
        textView.onKeyDown = { [weak self] event in
            self?.onKeyDown(event) ?? false
        }
        textView.onPageTap = { [weak self] forward in
            self?.onPageTap(forward)
            return true
        }
        textView.onBuildSelectionMenu = { [weak self] range in
            self?.onBuildSelectionMenu(range) ?? []
        }
    }

}
#endif
