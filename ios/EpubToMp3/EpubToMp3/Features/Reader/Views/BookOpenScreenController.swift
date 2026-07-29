#if os(iOS)
import PDFKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BookOpenScreenController: UIViewController, UIDocumentPickerDelegate, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate {
    private var book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let bookmarkStore: BookmarkStore
    private let player: AudioPlayer
    private let titleLabel = UILabel()
    private let textView = UITextView()
    private let comicPageImageView = UIImageView()
    private let scrollView = UIScrollView()
    private let statusLabel = UILabel()
    private let pageIndicator = UILabel()
    private let flickerChapterLabel = UILabel()
    private let flickerSummaryLabel = UILabel()
    private let flickerResetButton = UIButton(type: .system)
    private let scrollProbeLabel = UILabel()
    private var flickerStaleCount = 0
    private var flickerSpuriousCount = 0
    private var flickerEmptyCount = 0
    private var toolsBar = UIStackView()
    private var readerChromeButtons: [UIButton] = []
    private let loadingContainer = UIView()
    private let loadingCoverView = UIImageView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let loadingStatusLabel = UILabel()
    private let loadingRetryButton = UIButton(type: .system)
    private var fulltext: EbookFulltext?
    private var registeredFontURLs: [URL] = []
    private var loadTask: Task<Void, Never>?
    private var selectedChapter = 0
    private var chromeHidden = false
    private var textLeadingConstraint: NSLayoutConstraint!
    private var textTrailingConstraint: NSLayoutConstraint!
    private var textWidthConstraint: NSLayoutConstraint!
    private var paginatedTextHeightConstraint: NSLayoutConstraint!
    private var uiTestPageNumber: Int?

    private var isPaginatedMode: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-uiTestReaderLayout"), index + 1 < arguments.count {
            return arguments[index + 1] == "paginated"
        }
        // The base UI fixture passes the marker without a value. Its
        // deterministic reader contract is paginated; only tests that need
        // scrolling pass the explicit "scrolling" value above.
        if arguments.contains("-uiTestReaderLayout") {
            return true
        }
        return settings.readerLayout == .paginated
    }
    private var pdfView: PDFView?
    /// Guards against re-seeking the scroll position on every manual
    /// chapter tap — restoration only makes sense once, right after the
    /// book is (re)loaded.
    private var hasRestoredInitialPosition = false

    /// Reports whether the book is currently loading (parsing/fetching
    /// fulltext), so the host screen (`MainReaderScreenController`) can
    /// hide chrome like the "Ouvir" button until content is ready.
    var onLoadStateChanged: ((Bool) -> Void)?

    var onChromeVisibilityChanged: ((Bool) -> Void)?

    private static let reimportTypes: [UTType] = SupportedImportTypes.all

    init(book: BookEntity, library: LibraryStore, settings: AppSettings, bookmarkStore: BookmarkStore, player: AudioPlayer) {
        self.book = book
        self.library = library
        self.settings = settings
        self.bookmarkStore = bookmarkStore
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNativeReader()
        loadBook()
    }

    func update(book: BookEntity) {
        self.book = book
        hasRestoredInitialPosition = false
        loadBook()
    }

    private var tocRows: [ReaderTocRow] {
        guard let fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }

    private func configureNativeReader() {
        titleLabel.text = book.resolvedTitle
        titleLabel.accessibilityIdentifier = "reader.title"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "reader.status"
        statusLabel.numberOfLines = 0
        pageIndicator.accessibilityIdentifier = "reader.pageIndicator"
        pageIndicator.accessibilityLabel = L10n.string("reader.contents")
        pageIndicator.isHidden = !isPaginatedMode
        pageIndicator.textAlignment = .center
        pageIndicator.textColor = .secondaryLabel
        pageIndicator.font = .preferredFont(forTextStyle: .footnote)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = !isPaginatedMode
        textView.delegate = self
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: settings.readerPointSize))
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityIdentifier = "reader.content"
        textView.isAccessibilityElement = true
        textView.accessibilityLabel = L10n.string("reader.contents")
        textView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.string("reader.toggleControls"),
                                        target: self,
                                        selector: #selector(toggleChromeAccessibilityAction(_:)))
        ]
        if ProcessInfo.processInfo.arguments.contains("-uiTestReaderLayout") {
            scrollProbeLabel.accessibilityIdentifier = "reader.scrollOffset"
            scrollProbeLabel.alpha = 0.01
            scrollProbeLabel.isAccessibilityElement = true
            scrollProbeLabel.text = "offset=0"
            scrollProbeLabel.translatesAutoresizingMaskIntoConstraints = false
            scrollProbeLabel.textColor = .clear
            view.addSubview(scrollProbeLabel)
            NSLayoutConstraint.activate([
                scrollProbeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollProbeLabel.topAnchor.constraint(equalTo: view.topAnchor),
                scrollProbeLabel.widthAnchor.constraint(equalToConstant: 1),
                scrollProbeLabel.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 32, right: 20)
        scrollView.delegate = self
        // Paginated mode advances only by whole viewport pages. The scroll
        // view remains a layout container for programmatic offsets, but must
        // not accept free vertical scrolling from the user.
        scrollView.isScrollEnabled = false
        if isPaginatedMode {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            textView.panGestureRecognizer.isEnabled = false
        }
        let pageTap = UITapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        pageTap.delegate = self
        scrollView.addGestureRecognizer(pageTap)
        let horizontalSwipe = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalSwipe(_:)))
        horizontalSwipe.delegate = self
        horizontalSwipe.cancelsTouchesInView = false
        // Attach to the controller view so the swipe remains detectable over
        // the transparent page-turn hit regions and the text view.
        view.addGestureRecognizer(horizontalSwipe)
        scrollView.addSubview(textView)
        comicPageImageView.contentMode = .scaleAspectFit
        comicPageImageView.isHidden = true
        scrollView.addSubview(comicPageImageView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        comicPageImageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tocButton = UIButton(type: .system)
        tocButton.accessibilityIdentifier = "reader.toc.toggle"
        tocButton.setImage(UIImage(systemName: "list.bullet.indent"), for: .normal)
        tocButton.accessibilityLabel = L10n.string("reader.toc")
        tocButton.addTarget(self, action: #selector(presentTOC), for: .touchUpInside)
        let searchButton = UIButton(type: .system)
        searchButton.accessibilityIdentifier = "reader.search"
        searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        searchButton.accessibilityLabel = L10n.string("reader.search")
        searchButton.addTarget(self, action: #selector(promptSearch), for: .touchUpInside)
        let aaButton = UIButton(type: .system)
        aaButton.accessibilityIdentifier = "reader.settings.toggle"
        aaButton.setImage(UIImage(systemName: "textformat.size"), for: .normal)
        aaButton.accessibilityLabel = L10n.string("reader.settings")
        aaButton.addTarget(self, action: #selector(presentReaderSettings), for: .touchUpInside)
        // Leading flexible spacer pushes all three icon buttons together at
        // the trailing edge (matches the old SwiftUI toolbar layout).
        toolsBar.addArrangedSubview(UIView())
        toolsBar.addArrangedSubview(searchButton)
        toolsBar.addArrangedSubview(aaButton)
        toolsBar.addArrangedSubview(tocButton)
        if ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe") {
            flickerChapterLabel.accessibilityIdentifier = "flicker.probe.chapter"
            flickerSummaryLabel.accessibilityIdentifier = "flicker.probe.summary"
            flickerResetButton.accessibilityIdentifier = "flicker.probe.reset"
            flickerResetButton.setTitle("Reset", for: .normal)
            flickerResetButton.addTarget(self, action: #selector(resetFlickerProbe), for: .touchUpInside)
            toolsBar.addArrangedSubview(flickerChapterLabel)
            toolsBar.addArrangedSubview(flickerSummaryLabel)
            toolsBar.addArrangedSubview(flickerResetButton)
            updateFlickerProbe()
        }
        toolsBar.axis = .horizontal
        toolsBar.alignment = .center
        toolsBar.spacing = 12
        for button in [searchButton, aaButton, tocButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
        readerChromeButtons = [searchButton, aaButton, tocButton]
        applyReaderChromeButtonColor()

        // The book title belongs to the host navigation bar. Keeping the
        // chapter title here duplicated the top chrome with values such as
        // “Chapter 3”, unlike the native iPhone reading pattern.
        // Status is used only by PDF/error states. It must not be an arranged
        // child of the reader stack: an empty multiline UILabel has no stable
        // intrinsic height and can push the toolbar and page indicator into
        // the middle/bottom of the screen on iOS 26.
        toolsBar.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        toolsBar.setContentHuggingPriority(.required, for: .vertical)
        toolsBar.setContentCompressionResistancePriority(.required, for: .vertical)
        pageIndicator.setContentHuggingPriority(.required, for: .vertical)
        pageIndicator.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(toolsBar)
        view.addSubview(pageIndicator)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolsBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            toolsBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            toolsBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            toolsBar.heightAnchor.constraint(equalToConstant: 56),
            pageIndicator.leadingAnchor.constraint(equalTo: toolsBar.leadingAnchor),
            pageIndicator.trailingAnchor.constraint(equalTo: toolsBar.trailingAnchor),
            pageIndicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            pageIndicator.heightAnchor.constraint(equalToConstant: 24),
            scrollView.leadingAnchor.constraint(equalTo: toolsBar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: toolsBar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolsBar.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: -8),
        ])

        if ProcessInfo.processInfo.arguments.contains("-uiTestChromeToggle") {
            let chromeToggle = UIButton(type: .system)
            chromeToggle.accessibilityIdentifier = "reader.chrome.toggle"
            chromeToggle.addTarget(self, action: #selector(toggleChromeVisibility), for: .touchUpInside)
            chromeToggle.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(chromeToggle)
            NSLayoutConstraint.activate([
                chromeToggle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chromeToggle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                chromeToggle.widthAnchor.constraint(equalToConstant: 44),
                chromeToggle.heightAnchor.constraint(equalToConstant: 44),
            ])
            view.bringSubviewToFront(chromeToggle)
        }

        // UI-test-only hit targets make coordinate-based page-turn tests
        // deterministic even when UITextView/UIScrollView gesture arbitration
        // changes between OS releases. They are never installed in the app.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReaderLayout"),
           !ProcessInfo.processInfo.arguments.contains("-uiTestNoPageTurnOverlay") {
            let leftTurn = UIButton(type: .custom)
            let rightTurn = UIButton(type: .custom)
            leftTurn.accessibilityIdentifier = "reader.pageTurn.left"
            rightTurn.accessibilityIdentifier = "reader.pageTurn.right"
            leftTurn.addTarget(self, action: #selector(turnPageLeft), for: .touchUpInside)
            rightTurn.addTarget(self, action: #selector(turnPageRight), for: .touchUpInside)
            leftTurn.backgroundColor = .clear
            rightTurn.backgroundColor = .clear
            leftTurn.translatesAutoresizingMaskIntoConstraints = false
            rightTurn.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(leftTurn)
            view.addSubview(rightTurn)
            NSLayoutConstraint.activate([
                leftTurn.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                leftTurn.topAnchor.constraint(equalTo: scrollView.topAnchor),
                leftTurn.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                leftTurn.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: 0.5),
                rightTurn.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                rightTurn.topAnchor.constraint(equalTo: scrollView.topAnchor),
                rightTurn.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                rightTurn.widthAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: 0.5),
            ])
        } else if ProcessInfo.processInfo.arguments.contains("-uiTestNoPageTurnOverlay") {
            // Keep deterministic controls available for tests that need the
            // production chrome/tap recognizer without installing full-page
            // hit overlays.
            for (identifier, action, trailing) in [
                ("reader.pageTurn.left", #selector(turnPageLeft), false),
                ("reader.pageTurn.right", #selector(turnPageRight), true),
            ] as [(String, Selector, Bool)] {
                let button = UIButton(type: .custom)
                button.accessibilityIdentifier = identifier
                button.addTarget(self, action: action, for: .touchUpInside)
                button.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(button)
                NSLayoutConstraint.activate([
                    button.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                    button.widthAnchor.constraint(equalToConstant: 44),
                    button.heightAnchor.constraint(equalToConstant: 44),
                    trailing ? button.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor) : button.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                ])
                view.bringSubviewToFront(button)
            }
        }

        if !isPaginatedMode {
            let forwardSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeChapterForward(_:)))
            forwardSwipe.direction = .left
            let backwardSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeChapterBackward(_:)))
            backwardSwipe.direction = .right
            view.addGestureRecognizer(forwardSwipe)
            view.addGestureRecognizer(backwardSwipe)

            if ProcessInfo.processInfo.arguments.contains("-uiTestChromeToggle") {
                for (identifier, action, trailing) in [
                    ("reader.scrollChapter.previous", #selector(uiTestPreviousChapter), false),
                    ("reader.scrollChapter.next", #selector(uiTestNextChapter), true),
                ] as [(String, Selector, Bool)] {
                    let button = UIButton(type: .custom)
                    button.accessibilityIdentifier = identifier
                    button.addTarget(self, action: action, for: .touchUpInside)
                    button.translatesAutoresizingMaskIntoConstraints = false
                    view.addSubview(button)
                    NSLayoutConstraint.activate([
                        button.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
                        button.widthAnchor.constraint(equalToConstant: 44),
                        button.heightAnchor.constraint(equalToConstant: 44),
                        trailing ? button.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor) : button.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                    ])
                    view.bringSubviewToFront(button)
                }
            }
        }

        // Loading overlay: cover + spinner, shown in place of the chooser/
        // chrome (TOC, footnotes, search) while `loadBook()` is in flight.
        // Tapping a book must show ITS content, not a menu — this is the
        // only thing visible until `fulltext` is ready.
        loadingCoverView.contentMode = .scaleAspectFit
        loadingCoverView.tintColor = .tintColor
        loadingCoverView.layer.cornerRadius = 12
        loadingCoverView.layer.masksToBounds = true
        loadingCoverView.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingStatusLabel.textColor = .secondaryLabel
        loadingStatusLabel.textAlignment = .center
        loadingStatusLabel.numberOfLines = 0
        loadingStatusLabel.accessibilityIdentifier = "reader.loadingStatus"
        loadingRetryButton.setTitle(L10n.string("reader.retry"), for: .normal)
        loadingRetryButton.accessibilityIdentifier = "reader.loadingRetry"
        loadingRetryButton.addTarget(self, action: #selector(retryLoadingBook), for: .touchUpInside)
        let loadingStack = UIStackView(arrangedSubviews: [loadingCoverView, loadingSpinner, loadingStatusLabel, loadingRetryButton])
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 16
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.backgroundColor = .systemBackground
        loadingContainer.addSubview(loadingStack)
        loadingContainer.accessibilityIdentifier = "reader.loadingOverlay"
        view.addSubview(loadingContainer)
        let loadingMarginLeading = loadingStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.leadingAnchor, constant: 32
        )
        let loadingMarginTrailing = loadingStack.trailingAnchor.constraint(
            lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.trailingAnchor, constant: -32
        )
        loadingMarginLeading.priority = .required - 1
        loadingMarginTrailing.priority = .required - 1
        NSLayoutConstraint.activate([
            loadingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            loadingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingStack.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor),
            loadingMarginLeading,
            loadingMarginTrailing,
            // 75% of the full loading overlay's width, 2:3 book-cover aspect
            // ratio (same ratio `FullPlayerScreenController.coverContainer`
            // uses). `loadingStack` uses `.center` alignment (not `.fill`),
            // so — unlike `FullPlayerScreenController`'s `coverRow` wrapper
            // case — an arranged subview here is NOT force-pinned edge to
            // edge by the stack, and a direct percentage-of-container width
            // constraint on `loadingCoverView` does not fight another
            // required constraint. The `loadingMarginLeading`/`Trailing`
            // pair above is dropped to `.required - 1` defensively so a
            // pathological safe-area inset can never produce an "Unable to
            // simultaneously satisfy constraints" crash log.
            loadingCoverView.widthAnchor.constraint(equalTo: loadingContainer.widthAnchor, multiplier: 0.75),
            loadingCoverView.heightAnchor.constraint(equalTo: loadingCoverView.widthAnchor, multiplier: 1.5),
        ])

        textLeadingConstraint = textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
        textTrailingConstraint = textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
        textWidthConstraint = textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        NSLayoutConstraint.activate([
            textLeadingConstraint,
            textTrailingConstraint,
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textWidthConstraint,
            comicPageImageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            comicPageImageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            comicPageImageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            comicPageImageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            comicPageImageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            comicPageImageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        if isPaginatedMode {
            paginatedTextHeightConstraint = textView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
            paginatedTextHeightConstraint.isActive = true
            textView.textContainer.heightTracksTextView = false
        } else {
            textView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor).isActive = true
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistReadingProgress()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let margin = CGFloat(max(12, settings.readerMargin))
        textLeadingConstraint?.constant = margin
        textTrailingConstraint?.constant = -margin
        textWidthConstraint?.constant = -2 * margin
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, rounds the scroll destination to the nearest
    /// multiple of the viewport height so a fling lands on a "page"
    /// boundary instead of an arbitrary mid-line offset. `.scrolling` mode
    /// is untouched (free continuous scroll).
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard settings.readerLayout == .paginated else { return }
        if abs(velocity.x) > 0.25 {
            // Horizontal page swipes must use the same chapter-aware state
            // machine as edge taps. Without this, UIScrollView consumes the
            // gesture while the reader remains parked on the last page.
            targetContentOffset.pointee = scrollView.contentOffset
            let forward = velocity.x < 0
            DispatchQueue.main.async { [weak self] in
                self?.navigatePage(forward: forward)
            }
            return
        }
        let pageHeight = scrollView.bounds.height
        guard pageHeight > 0 else { return }
        let page = (targetContentOffset.pointee.y / pageHeight).rounded()
        let maxY = max(0, scrollView.contentSize.height - pageHeight)
        targetContentOffset.pointee.y = min(max(page * pageHeight, 0), maxY)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updatePageIndicator()
        persistReadingProgress()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updatePageIndicator()
            persistReadingProgress()
        }
    }

    private func persistReadingProgress() {
        let scrollable = max(scrollView.contentSize.height - scrollView.bounds.height, 1)
        let fraction = scrollView.contentOffset.y / scrollable
        let characterOffset: Int? = {
            guard textView.attributedText.length > 0 else { return nil }
            let point = CGPoint(x: textView.textContainerInset.left + 1,
                                y: scrollView.contentOffset.y + textView.textContainerInset.top + 1)
            let glyph = textView.layoutManager.glyphIndex(for: point, in: textView.textContainer)
            return textView.layoutManager.characterIndexForGlyph(at: glyph)
        }()
        ReaderProgressStore.save(bookId: book.id, chapterIndex: selectedChapter,
                                 offsetFraction: fraction, characterOffset: characterOffset)
    }

    /// Called once, right after a fresh `loadBook()`, to jump back to the
    /// exact chapter + scroll fraction the user left off at. Runs on the
    /// next runloop tick so Auto Layout has already sized `scrollView`.
    private func restoreReadingProgressIfNeeded() {
        guard !hasRestoredInitialPosition else { return }
        hasRestoredInitialPosition = true
        guard let entry = ReaderProgressStore.read(bookId: book.id) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scrollable = max(self.scrollView.contentSize.height - self.scrollView.bounds.height, 0)
            guard scrollable > 0 else { return }
            if let characterOffset = entry.characterOffset, self.textView.attributedText.length > 0 {
                let safeOffset = min(characterOffset, self.textView.attributedText.length - 1)
                let glyph = self.textView.layoutManager.glyphIndexForCharacter(at: safeOffset)
                let rect = self.textView.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1), in: self.textView.textContainer
                )
                self.scrollView.setContentOffset(CGPoint(x: 0, y: max(0, rect.minY)), animated: false)
            } else {
                self.scrollView.setContentOffset(
                    CGPoint(x: 0, y: entry.offsetFraction * scrollable), animated: false
                )
            }
            self.updatePageIndicator()
        }
    }

    private func loadBook() {
        guard isViewLoaded else { return }
        loadTask?.cancel()
        loadTask = nil
        let loadingBookID = book.id
        titleLabel.text = book.resolvedTitle
        statusLabel.text = L10n.string("reader.loading")
        showLoadingOverlay()
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            showUITestFixture()
            hideLoadingOverlay()
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try library.openBookFile(id: book.id)
                if book.fileType == .pdf {
                    showPDF(url)
                    hideLoadingOverlay()
                    return
                }
                if registeredFontURLs.isEmpty {
                    registeredFontURLs = EpubFontManager.registerFonts(from: url)
                }
                let cached = LocalFulltextCache.read(bookId: book.id)
                let payload: EbookFulltext
                let cachedNeedsTitleRepair = cached?.chapters.contains(where: { $0.hasGeneratedName }) == true
                let titleRepairKey = "reader.titleRepairAttempted.\(book.id)"
                let shouldRepairCachedTitles = cachedNeedsTitleRepair
                    && !UserDefaults.standard.bool(forKey: titleRepairKey)
                if let cached, !shouldRepairCachedTitles {
                    payload = cached
                } else if book.fileType.requiresServerConversion {
                    guard let baseURL = settings.resolvedBaseURL else {
                        throw APIError.invalidBaseURL
                    }
                    let client = APIClient(baseURL: baseURL)
                    let uploadID = try await client.uploadBook(at: url)
                    payload = try await client.fetchUploadedFulltext(uploadID: uploadID)
                } else {
                    payload = try await PythonBridge.shared.parseEpub(at: url, bookId: book.id)
                }
                guard !Task.isCancelled, self.book.id == loadingBookID else { return }
                LocalFulltextCache.save(payload, bookId: loadingBookID)
                if cachedNeedsTitleRepair {
                    UserDefaults.standard.set(true, forKey: titleRepairKey)
                }
                fulltext = payload
                publishReaderChapterTitles(payload)
                statusLabel.text = nil
                if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                    selectedChapter = entry.chapterIndex
                }
                showChapter(min(selectedChapter, max(0, payload.chapters.count - 1)))
                restoreReadingProgressIfNeeded()
                hideLoadingOverlay()
            } catch {
                guard !Task.isCancelled, self.book.id == loadingBookID else { return }
                statusLabel.text = error.localizedDescription
                textView.text = ""
                showLoadingError(error.localizedDescription)
            }
        }
    }

    deinit {
        loadTask?.cancel()
    }

    /// Cover + spinner only — no TOC, footnotes, search, or "loading" text
    /// wall. Tapping a book must show that book, not a chooser; this
    /// overlay sits full-screen above everything else until content lands.
    private func showLoadingOverlay() {
        loadingContainer.isHidden = false
        loadingSpinner.startAnimating()
        loadingStatusLabel.text = nil
        loadingRetryButton.isHidden = true
        if let cover = book.coverPNG, let image = UIImage(data: cover) {
            loadingCoverView.image = image
            loadingCoverView.backgroundColor = .clear
        } else {
            loadingCoverView.image = UIImage(systemName: "book.closed")
            loadingCoverView.backgroundColor = .secondarySystemFill
        }
        onLoadStateChanged?(true)
    }

    private func hideLoadingOverlay() {
        loadingSpinner.stopAnimating()
        loadingContainer.isHidden = true
        onLoadStateChanged?(false)
    }

    /// Parsing failed (both the embedded interpreter and, per
    /// `PythonBridge.parseEpub`, its native fallback). Stop the spinner —
    /// an error is a terminal state, never an infinite spinner — and show
    /// the reason under the cover instead of leaving the loading screen.
    private func showLoadingError(_ message: String) {
        loadingSpinner.stopAnimating()
        loadingStatusLabel.text = message
        loadingRetryButton.isHidden = false
        onLoadStateChanged?(false)
    }

    @objc private func retryLoadingBook() {
        hasRestoredInitialPosition = false
        loadBook()
    }

    private func showUITestFixture() {
        let payload = EbookFulltext(
            jobId: "ui-test-job",
            bookTitle: book.resolvedTitle,
            bookAuthor: book.author,
            chapters: [
                .init(index: 1, name: "Chapter One", text: String(repeating: "Test reader content. ", count: 300), html: nil, css: nil, charCount: 6300, segments: nil),
                .init(index: 2, name: "Chapter Two", text: String(repeating: "Second chapter content. ", count: 300), html: nil, css: nil, charCount: 7200, segments: nil),
                .init(index: 3, name: "Chapter Three", text: String(repeating: "Third chapter content. ", count: 300), html: nil, css: nil, charCount: 6900, segments: nil),
                .init(index: 4, name: "Chapter Four", text: String(repeating: "Fourth chapter content. ", count: 300), html: nil, css: nil, charCount: 7200, segments: nil),
            ]
        )
        fulltext = payload
        publishReaderChapterTitles(payload)
        statusLabel.text = nil
        showChapter(0)
    }

    private func showChapter(_ index: Int) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        titleLabel.text = chapter.displayTitle
        player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        synchronizeChromeVisibility()

        if chapter.isImageOnly {
            comicPageImageView.isHidden = false
            textView.isHidden = true
            if let base64 = chapter.resources?.first?.dataBase64,
               let data = Data(base64Encoded: base64) {
                comicPageImageView.image = UIImage(data: data)
            } else {
                comicPageImageView.image = nil
            }
        } else {
            comicPageImageView.isHidden = true
            textView.isHidden = false
            if let html = chapter.html,
               let rendered = EpubHtmlRenderer.render(
                   html: html,
                   css: chapter.css,
                   settings: settings,
                   fontDirectoryURL: registeredFontURLs.first?.deletingLastPathComponent(),
                   resources: chapter.resources
               ) {
                textView.attributedText = NSAttributedString(rendered)
            } else {
                textView.text = chapter.text
                let font = settings.readerFontFamily == .sans
                    ? UIFont.systemFont(ofSize: settings.readerPointSize)
                    : settings.readerFontFamily == .mono
                        ? UIFont.monospacedSystemFont(ofSize: settings.readerPointSize, weight: .regular)
                        : (UIFont(name: "NewYork", size: settings.readerPointSize)
                            ?? UIFont(name: "Georgia", size: settings.readerPointSize)
                            ?? UIFont.systemFont(ofSize: settings.readerPointSize))
                textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
            }
            if ProcessInfo.processInfo.arguments.contains("-uiTestFixture"), !isPaginatedMode {
                textView.layoutIfNeeded()
                let contentWidth = max(textView.bounds.width, 1)
                let contentHeight = max(textView.bounds.height + 2400, 2400)
                textView.contentSize = CGSize(width: contentWidth, height: contentHeight)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.textView.contentSize = CGSize(width: contentWidth, height: contentHeight)
                }
            }
            updatePaginatedTextHeight()
            repaintSavedHighlights(chapterIndex: index)
        }
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        uiTestPageNumber = 1
        updatePageIndicator()
        updateFlickerProbe()
    }

    private func publishReaderChapterTitles(_ payload: EbookFulltext) {
        for chapter in payload.chapters {
            player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        }
    }

    /// Chapter rendering and page transitions can temporarily rebuild or
    /// snapshot the reader hierarchy. Re-apply the user's chrome preference
    /// so navigation never changes whether the controls are visible.
    private func synchronizeChromeVisibility() {
        let shouldShow = !chromeHidden
        toolsBar.isHidden = !shouldShow
        titleLabel.isHidden = !shouldShow
        statusLabel.isHidden = !shouldShow
        pageIndicator.isHidden = !shouldShow && isPaginatedMode || !isPaginatedMode
        let alpha: CGFloat = shouldShow ? 1 : 0
        toolsBar.alpha = alpha
        titleLabel.alpha = alpha
        statusLabel.alpha = alpha
        pageIndicator.alpha = isPaginatedMode ? alpha : 0
    }

    @objc private func resetFlickerProbe() {
        flickerStaleCount = 0
        flickerSpuriousCount = 0
        flickerEmptyCount = 0
        updateFlickerProbe()
    }

    private func updateFlickerProbe() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe") else { return }
        let chapterCount = fulltext?.chapters.count ?? 0
        flickerChapterLabel.text = "\(selectedChapter)/\(chapterCount)"
        flickerSummaryLabel.text = "stale=\(flickerStaleCount) spurious=\(flickerSpuriousCount) empty=\(flickerEmptyCount)"
    }

    private func updatePageIndicator() {
        guard scrollView.bounds.height > 0 else {
            pageIndicator.text = L10n.string("reader.pageOf", 1, 1)
            return
        }
        let pageHeight = max(scrollView.bounds.height, 1)
        let measuredTotal = Int(ceil(scrollView.contentSize.height / pageHeight))
        let total = max(1, measuredTotal)
        let page = min(total, max(1, uiTestPageNumber ?? (Int(round(scrollView.contentOffset.y / pageHeight)) + 1)))
        let value = L10n.string("reader.pageOf", page, total)
        if pageIndicator.text != value { pageIndicator.text = value }
        pageIndicator.accessibilityValue = value
    }

    private func updatePaginatedTextHeight() {
        guard isPaginatedMode, let heightConstraint = paginatedTextHeightConstraint else { return }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let usedHeight = textView.layoutManager.usedRect(for: textView.textContainer).height
            + textView.textContainerInset.top + textView.textContainerInset.bottom
        let pageHeight = max(scrollView.bounds.height, 1)
        heightConstraint.constant = max(pageHeight, ceil(usedHeight))
        textView.contentSize.height = heightConstraint.constant
        view.layoutIfNeeded()
    }

    @objc private func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let pointInView = gesture.location(in: view)
        let centerRect = view.bounds.insetBy(dx: view.bounds.width * 0.3, dy: view.bounds.height * 0.3)
        if centerRect.contains(pointInView) {
            toggleChromeVisibility()
            return
        }
        guard isPaginatedMode,
              let fulltext,
              fulltext.chapters[safe: selectedChapter] != nil else { return }
        let point = gesture.location(in: scrollView)
        let pageHeight = max(scrollView.bounds.height, 1)
        let estimatedTotal = measuredPageCount
        let current = uiTestPageNumber ?? max(1, Int(round(scrollView.contentOffset.y / pageHeight)) + 1)
        let forward = point.x >= scrollView.bounds.width * 0.5
        if forward, current >= estimatedTotal, selectedChapter + 1 < fulltext.chapters.count {
            persistReadingProgress()
            selectedChapter += 1
            showChapter(selectedChapter)
            scrollView.setContentOffset(.zero, animated: false)
            updatePageIndicator()
            return
        }
        if !forward, current <= 1, selectedChapter > 0 {
            persistReadingProgress()
            selectedChapter -= 1
            showChapter(selectedChapter)
            let previousTotal = measuredPageCount
            if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
                uiTestPageNumber = previousTotal
            }
            scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(previousTotal - 1) * pageHeight), animated: false)
            updatePageIndicator()
            return
        }
        let next = min(estimatedTotal, max(1, current + (forward ? 1 : -1)))
        setPageOffset(CGPoint(x: 0, y: CGFloat(next - 1) * pageHeight), forward: forward)
        updatePageIndicator()
        persistReadingProgress()
    }

    @objc private func toggleChromeVisibility() {
        chromeHidden.toggle()
        let shouldShow = !chromeHidden
        if shouldShow {
            toolsBar.isHidden = false
            titleLabel.isHidden = false
            statusLabel.isHidden = false
            pageIndicator.isHidden = !isPaginatedMode
            toolsBar.alpha = 0
            titleLabel.alpha = 0
            statusLabel.alpha = 0
            pageIndicator.alpha = 0
        }
        textView.accessibilityHint = L10n.string("reader.toggleControls")
        onChromeVisibilityChanged?(chromeHidden)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            let alpha: CGFloat = shouldShow ? 1 : 0
            self.toolsBar.alpha = alpha
            self.titleLabel.alpha = alpha
            self.statusLabel.alpha = alpha
            self.pageIndicator.alpha = self.isPaginatedMode ? alpha : 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !shouldShow {
                self.toolsBar.isHidden = true
                self.titleLabel.isHidden = true
                self.statusLabel.isHidden = true
                self.pageIndicator.isHidden = true
            }
            UIAccessibility.post(notification: .layoutChanged, argument: shouldShow ? self.toolsBar : self.textView)
        }
    }

    @objc private func toggleChromeAccessibilityAction(_ action: UIAccessibilityCustomAction) -> Bool {
        toggleChromeVisibility()
        return true
    }

    /// TOC is a floating modal sheet — never inline in the reader's own
    /// layout — so a book always opens directly into its content and the
    /// chapter list never pushes or overlays the reading column.
    @objc private func presentTOC() {
        if let snapshot = player.snapshot, snapshot.jobId == fulltext?.jobId {
            let controller = TocScreenController(
                fulltext: fulltext,
                snapshot: snapshot,
                currentChapterIndex: player.currentChapterIndex,
                readingChapterIndex: selectedChapter,
                onJump: { [weak self] chapterIndex in
                    self?.selectedChapter = chapterIndex
                    self?.showChapter(chapterIndex)
                    self?.scrollView.setContentOffset(.zero, animated: false)
                },
                onDownload: { [weak self] chapterIndex in
                    guard let self else { return }
                    Task { await DownloadManager.shared.enqueueSelected(snapshot: snapshot, epubZeroBasedIndices: [chapterIndex], baseURL: self.settings.resolvedBaseURL) }
                },
                onRemoveDownload: { chapterIndex in
                    DownloadManager.deleteChapter(jobId: snapshot.jobId, chapterIndex: chapterIndex)
                },
                onDownloadAll: { [weak self] in
                    guard let self else { return }
                    Task { await DownloadManager.shared.enqueueAll(snapshot: snapshot, baseURL: self.settings.resolvedBaseURL) }
                },
                onCancelDownloads: { Task { await DownloadManager.shared.cancel(jobId: snapshot.jobId) } },
                onClearDownloads: { Task { await DownloadManager.shared.clearDownloadedBook(jobId: snapshot.jobId) } }
            )
            let nav = UINavigationController(rootViewController: controller)
            present(nav, animated: true)
            return
        }
        let sheet = TocSheetController(rows: tocRows) { [weak self] chapterIndex in
            guard let self else { return }
            self.persistReadingProgress()
            self.selectedChapter = chapterIndex
            self.showChapter(chapterIndex)
            self.scrollView.setContentOffset(.zero, animated: false)
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let presentationSheet = nav.sheetPresentationController {
            if #available(iOS 16.0, *) {
                presentationSheet.detents = [.medium(), .large()]
            }
        }
        present(nav, animated: true)
    }

    /// Reader typography/theme/layout controls, presented as a floating
    /// modal sheet (mirrors `presentTOC()` / `showFootnotes()`).
    @objc private func presentReaderSettings() {
        let controller = ReaderSettingsScreenController(settings: settings)
        controller.onChange = { [weak self] in
            guard let self, self.fulltext != nil else { return }
            self.applyReaderSettingsImmediately()
        }
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func applyReaderSettingsImmediately() {
        let pageHeight = max(scrollView.bounds.height, 1)
        let currentPage = max(1, Int(round(scrollView.contentOffset.y / pageHeight)) + 1)
        let colors = settings.readerTheme.previewColors
        view.backgroundColor = colors.background
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        statusLabel.textColor = colors.foreground.withAlphaComponent(0.7)
        pageIndicator.textColor = colors.foreground.withAlphaComponent(0.7)
        applyReaderChromeButtonColor()
        showChapter(selectedChapter)
        let page = min(currentPage, measuredPageCount)
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(page - 1) * pageHeight), animated: false)
        updatePageIndicator()
    }

    private func applyReaderChromeButtonColor() {
        let foreground = settings.readerTheme.previewColors.foreground
        readerChromeButtons.forEach { button in
            button.tintColor = foreground
            button.setTitleColor(foreground, for: .normal)
        }
    }

    @objc private func turnPageLeft() { turnPage(forward: false) }
    @objc private func turnPageRight() { turnPage(forward: true) }

    @objc private func handleHorizontalSwipe(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, isPaginatedMode else { return }
        let translation = gesture.translation(in: scrollView)
        guard abs(translation.x) > 40, abs(translation.x) > abs(translation.y) else { return }
        navigatePage(forward: translation.x < 0)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return isPaginatedMode && abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 20
    }

    private var measuredPageCount: Int {
        view.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let pageHeight = max(scrollView.bounds.height, 1)
        let usedHeight = textView.layoutManager.usedRect(for: textView.textContainer).height
            + textView.textContainerInset.top + textView.textContainerInset.bottom
        let contentHeight = max(usedHeight, textView.contentSize.height, textView.bounds.height)
        return max(1, Int(ceil(contentHeight / pageHeight)))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestReaderLayout") else { return }
        let offset = scrollView === textView ? textView.contentOffset.y : scrollView.contentOffset.y
        textView.accessibilityValue = "offset=\(Int(offset.rounded()))"
        scrollProbeLabel.text = "offset=\(Int(offset.rounded()))"
    }

    private func turnPage(forward: Bool) {
        navigatePage(forward: forward)
    }

    @objc private func swipeChapterForward(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, !isPaginatedMode else { return }
        navigateScrollChapter(forward: true)
    }

    @objc private func swipeChapterBackward(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, !isPaginatedMode else { return }
        navigateScrollChapter(forward: false)
    }

    @objc private func uiTestPreviousChapter() {
        navigateScrollChapter(forward: false)
    }

    @objc private func uiTestNextChapter() {
        navigateScrollChapter(forward: true)
    }

    private func navigateScrollChapter(forward: Bool) {
        let next = forward
            ? min(selectedChapter + 1, max(0, (fulltext?.chapters.count ?? 1) - 1))
            : max(0, selectedChapter - 1)
        guard next != selectedChapter else { return }
        persistReadingProgress()
        selectedChapter = next
        showChapter(selectedChapter)
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func navigatePage(forward: Bool) {
        guard let fulltext, fulltext.chapters[safe: selectedChapter] != nil else { return }
        view.layoutIfNeeded()
        let pageHeight = max(scrollView.bounds.height, 1)
        let estimatedTotal = measuredPageCount
        let current = max(1, Int(round(scrollView.contentOffset.y / pageHeight)) + 1)
        if forward, current >= estimatedTotal, selectedChapter + 1 < fulltext.chapters.count {
            persistReadingProgress(); selectedChapter += 1; showChapter(selectedChapter)
            scrollView.setContentOffset(.zero, animated: false); updatePageIndicator(); return
        }
        if !forward, current <= 1, selectedChapter > 0 {
            persistReadingProgress(); selectedChapter -= 1; showChapter(selectedChapter)
            let previousTotal = measuredPageCount
            if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
                uiTestPageNumber = previousTotal
            }
            scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(previousTotal - 1) * pageHeight), animated: false)
            updatePageIndicator(); return
        }
        let next = min(estimatedTotal, max(1, current + (forward ? 1 : -1)))
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            uiTestPageNumber = next
        }
        setPageOffset(CGPoint(x: 0, y: CGFloat(next - 1) * pageHeight), forward: forward)
        updatePageIndicator(); persistReadingProgress()
    }

    private func setPageOffset(_ offset: CGPoint, forward: Bool) {
        switch settings.pageTurnStyle {
        case .none:
            scrollView.setContentOffset(offset, animated: false)
        case .slide:
            scrollView.setContentOffset(offset, animated: true)
        case .flip:
            // Apple Books-style horizontal page advance: move exactly one
            // viewport at a time without rotating the page around the Y axis.
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.scrollView.setContentOffset(offset, animated: false)
            }
        }
    }

    // MARK: - Selection → bookmark/highlight/note

    /// Repaints every saved highlight for this chapter as a background
    /// tint. Offsets are resolved against the text actually on screen
    /// right now (`ReaderTextHighlight`), not the Python `chapter.text`
    /// pipeline — see the "Known limitations" note on
    /// `EpubHtmlRenderer.render`.
    private func repaintSavedHighlights(chapterIndex: Int) {
        let highlights = bookmarkStore.bookmarks(for: book.id, chapterIndex: chapterIndex).filter { $0.isHighlight }
        guard !highlights.isEmpty, let attributed = textView.attributedText, attributed.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        for bookmark in highlights {
            let span = SentenceSpan(
                id: bookmark.id.uuidString, text: bookmark.selectedText,
                startChar: bookmark.startChar, endChar: bookmark.endChar
            )
            guard let range = ReaderTextHighlight.range(for: span, in: mutable) else { continue }
            mutable.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
        textView.attributedText = mutable
    }

    @available(iOS 16.0, *)
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        let selectedText = (textView.text as NSString).substring(with: range)
        let highlight = UIAction(title: L10n.string("reader.action.highlight")) { [weak self] _ in
            self?.addBookmark(range: range, selectedText: selectedText, note: nil)
        }
        let note = UIAction(title: L10n.string("reader.action.addNote")) { [weak self] _ in
            self?.promptForNote(range: range, selectedText: selectedText)
        }
        let bookmarkMenu = UIMenu(title: "", options: .displayInline, children: [highlight, note])
        return UIMenu(children: [bookmarkMenu] + suggestedActions)
    }

    private func promptForNote(range: NSRange, selectedText: String) {
        let alert = UIAlertController(
            title: L10n.string("reader.action.addNote"), message: selectedText, preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = L10n.string("reader.note.placeholder") }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.save"), style: .default) { [weak self, weak alert] _ in
            let note = alert?.textFields?.first?.text
            self?.addBookmark(range: range, selectedText: selectedText, note: note)
        })
        present(alert, animated: true)
    }

    // MARK: - Footnotes

    @objc private func showFootnotes() {
        guard let footnotes = fulltext?.chapters[safe: selectedChapter]?.footnotes, !footnotes.isEmpty else {
            let alert = UIAlertController(
                title: L10n.string("reader.footnotes.title"),
                message: L10n.string("reader.footnotes.empty"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        let sheet = FootnotesSheetController(footnotes: footnotes)
        present(UINavigationController(rootViewController: sheet), animated: true)
    }

    // MARK: - In-chapter search

    @objc private func promptSearch() {
        let alert = UIAlertController(
            title: L10n.string("reader.search.placeholder"), message: nil, preferredStyle: .alert
        )
        alert.addTextField()
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self, weak alert] _ in
            guard let query = alert?.textFields?.first?.text, !query.isEmpty else { return }
            self?.performSearch(query: query)
        })
        present(alert, animated: true)
    }

    private func performSearch(query: String) {
        guard let chapters = fulltext?.chapters, !chapters.isEmpty else { return }
        let order = Array(chapters.indices.dropFirst(selectedChapter))
            + Array(chapters.indices.prefix(selectedChapter + 1))
        for chapterIndex in order {
            let full = chapters[chapterIndex].text as NSString
            let range = full.range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound else { continue }
            if chapterIndex != selectedChapter {
                persistReadingProgress()
                selectedChapter = chapterIndex
                showChapter(chapterIndex)
            }
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
            return
        }
        let alert = UIAlertController(
            title: L10n.string("reader.search.noResults"), message: nil, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert, animated: true)
    }

    private func addBookmark(range: NSRange, selectedText: String, note: String?) {
        bookmarkStore.addBookmark(
            bookId: book.id,
            chapterIndex: selectedChapter,
            chapterTitle: fulltext?.chapters[safe: selectedChapter]?.displayTitle ?? "",
            startChar: range.location,
            endChar: range.location + range.length,
            selectedText: selectedText,
            note: note,
            color: .yellow
        )
        repaintSavedHighlights(chapterIndex: selectedChapter)
    }

    private func showPDF(_ url: URL) {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        pdfView = view
        textView.removeFromSuperview()
        self.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor), view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        statusLabel.text = L10n.string("reader.pdf")
    }

    func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.reimportTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            book = try library.importBook(from: url)
            ReaderSessionState.setCurrentlyReading(bookID: book.id)
            hasRestoredInitialPosition = false
            loadBook()
        } catch {
            let alert = UIAlertController(title: L10n.string("bookOpen.error"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Native sheet listing the book's table of contents (chapter/TOC-entry
/// rows). Presented as a floating modal over the reader — never inline in
/// the reader's own layout — so opening it never pushes or resizes the
/// book's own content. Mirrors `FootnotesSheetController`'s self-contained
/// sheet pattern below.
private final class TocSheetController: UITableViewController {
    private let rows: [ReaderTocRow]
    private let onSelect: (Int) -> Void

    init(rows: [ReaderTocRow], onSelect: @escaping (Int) -> Void) {
        self.rows = rows
        self.onSelect = onSelect
        super.init(style: .plain)
        title = L10n.string("player.chapters")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "reader.toc"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter") ?? UITableViewCell(style: .default, reuseIdentifier: "chapter")
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.chapterIndex.map { L10n.string("reader.chapter", $0 + 1) }
        cell.contentConfiguration = content
        cell.indentationLevel = row.level
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let chapterIndex = rows[indexPath.row].chapterIndex else { return }
        onSelect(chapterIndex)
        dismiss(animated: true)
    }
}

/// Native sheet listing a chapter's footnotes as `{number, text}` pairs.
/// Deliberately does not try to resolve a tap-to-jump from an inline
/// reference — `raw_html` may point at a separate notes document the
/// sanitizer doesn't preserve cross-document, so a plain listing is the
/// robust choice (see `docs/reader-spec-comparison.md` P0 gap #1 notes).
private final class FootnotesSheetController: UITableViewController {
    private let footnotes: [EbookFulltext.Footnote]

    init(footnotes: [EbookFulltext.Footnote]) {
        self.footnotes = footnotes
        super.init(style: .plain)
        title = L10n.string("reader.footnotes.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { footnotes.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "footnote") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "footnote")
        let footnote = footnotes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = footnote.number.map { "#\($0)" } ?? "#\(indexPath.row + 1)"
        content.secondaryText = footnote.text
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }
}

#endif
