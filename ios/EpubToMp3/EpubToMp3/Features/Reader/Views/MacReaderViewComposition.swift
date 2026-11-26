#if os(macOS)
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
        let footnotes: Selector
        let listen: Selector
        let voiceModels: Selector
        let retryLoading: Selector

        init(close: Selector, contents: Selector, search: Selector, settings: Selector,
             footnotes: Selector = NSSelectorFromString("showFootnotes"),
             listen: Selector = NSSelectorFromString("listenFromReader"),
             voiceModels: Selector = NSSelectorFromString("showVoiceModels:"), retryLoading: Selector) {
            self.close = close
            self.contents = contents
            self.search = search
            self.settings = settings
            self.footnotes = footnotes
            self.listen = listen
            self.voiceModels = voiceModels
            self.retryLoading = retryLoading
        }
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
    let chaptersTable: NSTableView = {
        let table = NSTableView()
        table.setAccessibilityLabel(L10n.string("reader.contents"))
        return table
    }()
    let textView = MacReaderTextView()
    let comicPageImageView = NSImageView()
    let contentScrollView = NSScrollView()
    /// The paginated reader's "x of y", on its own strip below the text.
    let pageIndicator = NSTextField(labelWithString: "")
    private var contentBottomToSafeArea: NSLayoutConstraint?
    private var contentBottomToPageIndicator: NSLayoutConstraint?
    let toolbar = NSStackView()
    private let chromeBackground = NSVisualEffectView()
    let bookTitleLabel = NSTextField(labelWithString: "")
    let chapterTitleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let tocPopover = NSPopover()
    let settingsPopover = NSPopover()
    private var toolBar: MacReaderToolBar?

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

        let tools = MacReaderToolBar { [weak self] tool, sender in
            guard let self else { return }
            switch tool {
            case .appearance: self.target.perform(self.actions.settings, with: sender)
            case .contents: self.target.perform(self.actions.contents, with: sender)
            case .search: self.target.perform(self.actions.search)
            case .footnotes: self.target.perform(self.actions.footnotes)
            case .listen: self.target.perform(self.actions.listen)
            case .voiceModels: self.target.perform(self.actions.voiceModels, with: sender)
            }
        }
        toolBar = tools

        bookTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bookTitleLabel.alignment = .center
        bookTitleLabel.lineBreakMode = .byTruncatingTail
        bookTitleLabel.setAccessibilityIdentifier("reader.title")
        bookTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let leadingControls = NSStackView(views: [close])
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
        toolbar.addArrangedSubview(tools.recent)
        toolbar.addArrangedSubview(tools.more)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toolbar.spacing = 10
        toolbar.distribution = .fill
        // Equal spacers give the title a single position between the controls.
        let balance = leadingSpacer.widthAnchor.constraint(equalTo: trailingSpacer.widthAnchor)
        balance.priority = .defaultHigh
        balance.isActive = true
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = nil
        toolbar.setAccessibilityIdentifier("reader.toolbar")

        chapterTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        chapterTitleLabel.lineBreakMode = .byTruncatingTail
        chapterTitleLabel.setAccessibilityIdentifier("reader.chapterTitle")
        statusLabel.textColor = .readableSecondaryLabel
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
            textSettings: ReaderTextSettings(settings: settings),
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
        chromeBackground.material = .headerView
        chromeBackground.blendingMode = .withinWindow
        chromeBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeBackground, positioned: .above, relativeTo: contentScrollView)
        for chrome in [toolbar, chapterTitleLabel, statusLabel] {
            view.addSubview(chrome, positioned: .above, relativeTo: chromeBackground)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            chromeBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeBackground.topAnchor.constraint(equalTo: view.topAnchor),
            chromeBackground.bottomAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            chapterTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            chapterTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            chapterTitleLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: chapterTitleLabel.bottomAnchor, constant: 8),
            contentScrollView.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: chromeBackground.bottomAnchor),
        ])
        installPageIndicator(in: view)
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

    private func installPageIndicator(in view: NSView) {
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.alignment = .center
        pageIndicator.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pageIndicator.setAccessibilityIdentifier("reader.pageIndicator")
        pageIndicator.isHidden = true
        view.addSubview(pageIndicator)
        let toSafeArea = contentScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        contentBottomToSafeArea = toSafeArea
        contentBottomToPageIndicator = contentScrollView.bottomAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: -6)
        NSLayoutConstraint.activate([
            toSafeArea,
            pageIndicator.centerXAnchor.constraint(equalTo: contentScrollView.centerXAnchor),
            pageIndicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    /// Visibility follows the reading settings, never the chrome, so hiding the chrome does not reflow the page.
    func setPageIndicatorShown(_ shown: Bool) {
        guard pageIndicator.isHidden == shown else { return }
        pageIndicator.isHidden = !shown
        if shown {
            contentBottomToSafeArea?.isActive = false
            contentBottomToPageIndicator?.isActive = true
        } else {
            contentBottomToPageIndicator?.isActive = false
            contentBottomToSafeArea?.isActive = true
        }
    }

    func setFootnotesAvailable(_ available: Bool) { toolBar?.hasFootnotes = available }

    func setChromeHidden(_ hidden: Bool) {
        // Visibility never participates in the content constraints or text layout.
        for chrome in [toolbar, chapterTitleLabel, statusLabel, chromeBackground] { chrome.isHidden = hidden }
    }

    func protectPDFOpeningPosition(_ pdf: PDFView) {
        view.layoutSubtreeIfNeeded()
        guard pdf.document != nil else { return }
        pdf.layoutDocumentView()
        guard let documentView = pdf.documentView, let scroll = documentView.enclosingScrollView,
              scroll.isDescendant(of: pdf) else { return }
        let chrome = chromeBackground.convert(chromeBackground.bounds, to: scroll)
        let coveredHeight = scroll.bounds.intersection(chrome).height
        var insets = scroll.contentInsets
        guard coveredHeight > insets.top else { return }

        // Give the first page clearance at the leading scroll boundary. Keep the inset
        // fixed when chrome visibility changes so PDFKit preserves the exact reading offset.
        scroll.automaticallyAdjustsContentInsets = false
        insets.top = coveredHeight
        scroll.contentInsets = insets
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = clip.isFlipped
            ? documentView.frame.minY - insets.top
            : documentView.frame.maxY - bounds.height + insets.top
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
}
#endif
