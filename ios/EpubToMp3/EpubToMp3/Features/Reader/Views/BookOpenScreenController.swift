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
    private let textView = UITextView()
    private let comicPageImageView = UIImageView()
    private let scrollView = UIScrollView()
    private let pageIndicator = UILabel()
    private let flickerChapterLabel = UILabel()
    private let flickerSummaryLabel = UILabel()
    private let flickerResetButton = UIButton(type: .system)
    private let scrollProbeLabel = UILabel()
    private let paginationProbeLabel = UILabel()
    private lazy var pageTap = UITapGestureRecognizer(
        target: self,
        action: #selector(handleReaderTap(_:))
    )
    private lazy var forwardChapterSwipe = UISwipeGestureRecognizer(
        target: self,
        action: #selector(swipeChapterForward(_:))
    )
    private lazy var backwardChapterSwipe = UISwipeGestureRecognizer(
        target: self,
        action: #selector(swipeChapterBackward(_:))
    )
    private var flickerStaleCount = 0
    private var flickerSpuriousCount = 0
    private var flickerEmptyCount = 0
    private let testProbeStack = UIStackView()
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
    private var scrollingTextHeightConstraint: NSLayoutConstraint!
    private var scrollBottomToPageIndicator: NSLayoutConstraint!
    private var scrollBottomToSafeArea: NSLayoutConstraint!
    private var paginatedPageOffsets: [CGFloat] = [0]
    private var lastPaginatedViewportSize: CGSize = .zero
    private var lastScrollingViewportSize: CGSize = .zero
    private var settingsUpdateWorkItem: DispatchWorkItem?
    private var lastRenderedTextSettings: ReaderTextSettings?
    private var uiTestPageNumber: Int?
    /// Prevents overlapping page renders/snapshots when the user taps the
    /// reader edges repeatedly while a page transition is still running.
    private var isPageTransitioning = false

    private var isPaginatedMode: Bool {
        return settings.readerLayout == .paginated
    }

    private var isUITestFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestFixture")
    }

    private struct ReadingAnchor {
        let offsetFraction: CGFloat
        let characterOffset: Int?
    }
    private var lastInlineImageViewportWidth: CGFloat?
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

    private lazy var tocNavigationItem = makeNavigationItem(
        symbol: "list.bullet.indent",
        identifier: "reader.toc.toggle",
        label: L10n.string("reader.toc"),
        action: #selector(presentTOC)
    )
    private lazy var readerSettingsNavigationItem = makeNavigationItem(
        symbol: "textformat.size",
        identifier: "reader.settings.toggle",
        label: L10n.string("reader.settings"),
        action: #selector(presentReaderSettings)
    )
    private lazy var searchNavigationItem = makeNavigationItem(
        symbol: "magnifyingglass",
        identifier: "reader.search",
        label: L10n.string("reader.search"),
        action: #selector(promptSearch)
    )

    /// The host owns the iPhone navigation bar. Reader actions live there so
    /// the reading surface never creates a second toolbar below it.
    var navigationBarButtonItems: [UIBarButtonItem] {
        [tocNavigationItem, readerSettingsNavigationItem, searchNavigationItem]
    }

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
        pageIndicator.accessibilityIdentifier = "reader.pageIndicator"
        pageIndicator.accessibilityLabel = L10n.string("reader.contents")
        pageIndicator.isHidden = !isPaginatedMode || !settings.readerShowPageNumbers
        pageIndicator.textAlignment = .center
        pageIndicator.textColor = .secondaryLabel
        pageIndicator.font = .preferredFont(forTextStyle: .footnote)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
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
        if ProcessInfo.processInfo.arguments.contains("-uiTestPaginationProbe") {
            paginationProbeLabel.accessibilityIdentifier = "reader.paginationProbe"
            paginationProbeLabel.alpha = 0.01
            paginationProbeLabel.isAccessibilityElement = true
            paginationProbeLabel.textColor = .clear
            paginationProbeLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(paginationProbeLabel)
            NSLayoutConstraint.activate([
                paginationProbeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                paginationProbeLabel.topAnchor.constraint(equalTo: view.topAnchor),
                paginationProbeLabel.widthAnchor.constraint(equalToConstant: 1),
                paginationProbeLabel.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        // Horizontal gutters belong to the reader's margin setting. Keeping
        // the text container horizontal inset at zero makes the selected
        // value map directly to the visible reading column.
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 0, bottom: 32, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        scrollView.delegate = self
        pageTap.delegate = self
        pageTap.cancelsTouchesInView = false
        // Own reader gestures at the reader surface, not inside its scroll
        // view. UITextView and image chapters install their own recognizers;
        // attaching here guarantees that a deliberate centre tap always
        // reaches the immersive-reader action.
        view.addGestureRecognizer(pageTap)
        let horizontalSwipe = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalSwipe(_:)))
        horizontalSwipe.delegate = self
        horizontalSwipe.cancelsTouchesInView = false
        // Attach to the controller view so the swipe remains detectable over
        // the transparent page-turn hit regions and the text view.
        view.addGestureRecognizer(horizontalSwipe)
        forwardChapterSwipe.direction = .left
        backwardChapterSwipe.direction = .right
        view.addGestureRecognizer(forwardChapterSwipe)
        view.addGestureRecognizer(backwardChapterSwipe)
        scrollView.addSubview(textView)
        comicPageImageView.contentMode = .scaleAspectFit
        comicPageImageView.isHidden = true
        scrollView.addSubview(comicPageImageView)
        comicPageImageView.clipsToBounds = true
        comicPageImageView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        comicPageImageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        if ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe") {
            flickerChapterLabel.accessibilityIdentifier = "flicker.probe.chapter"
            flickerSummaryLabel.accessibilityIdentifier = "flicker.probe.summary"
            flickerResetButton.accessibilityIdentifier = "flicker.probe.reset"
            flickerResetButton.setTitle("Reset", for: .normal)
            flickerResetButton.addTarget(self, action: #selector(resetFlickerProbe), for: .touchUpInside)
            testProbeStack.addArrangedSubview(flickerChapterLabel)
            testProbeStack.addArrangedSubview(flickerSummaryLabel)
            testProbeStack.addArrangedSubview(flickerResetButton)
            updateFlickerProbe()
        }
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.setContentHuggingPriority(.required, for: .vertical)
        pageIndicator.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(pageIndicator)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            pageIndicator.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            pageIndicator.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            pageIndicator.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        scrollView.accessibilityIdentifier = "reader.viewport"
        scrollBottomToPageIndicator = scrollView.bottomAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: -8)
        scrollBottomToSafeArea = scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        configureTestProbeIfNeeded()

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

        if !isPaginatedMode,
           ProcessInfo.processInfo.arguments.contains("-uiTestChromeToggle") {
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
        // The two height constraints are retained so switching the reader
        // mode while the settings sheet is open is a layout update, not a
        // book reload.
        paginatedTextHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 1)
        scrollingTextHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 1)
        applyReaderLayoutMode()
    }

    private func applyReaderLayoutMode() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: settings.readerLayout,
            chromeHidden: chromeHidden,
            showsPageNumbers: settings.readerShowPageNumbers
        )
        scrollView.isScrollEnabled = configuration.allowsVerticalScrolling
        scrollView.panGestureRecognizer.isEnabled = configuration.allowsVerticalScrolling
        scrollView.alwaysBounceVertical = configuration.allowsVerticalScrolling
        scrollView.alwaysBounceHorizontal = false
        textView.isScrollEnabled = false
        textView.panGestureRecognizer.isEnabled = false
        textView.textContainer.widthTracksTextView = !configuration.usesPaginatedTextHeight
        textView.textContainer.heightTracksTextView = false
        paginatedTextHeightConstraint.isActive = configuration.usesPaginatedTextHeight
        scrollingTextHeightConstraint.isActive = !configuration.usesPaginatedTextHeight
        scrollBottomToPageIndicator.isActive = configuration.showsPageIndicator
        scrollBottomToSafeArea.isActive = !configuration.showsPageIndicator
        forwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        backwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        pageIndicator.isHidden = !configuration.showsPageIndicator
        pageIndicator.alpha = configuration.showsPageIndicator ? 1 : 0
        lastPaginatedViewportSize = .zero
        lastScrollingViewportSize = .zero
    }

    private func applyReaderMargins() {
        let margin = CGFloat(ReaderLayoutMetrics.clampedMargin(settings.readerMargin))
        textLeadingConstraint?.constant = margin
        textTrailingConstraint?.constant = -margin
        textWidthConstraint?.constant = -2 * margin
    }

    private func makeNavigationItem(
        symbol: String,
        identifier: String,
        label: String,
        action: Selector
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: symbol),
            style: .plain,
            target: self,
            action: action
        )
        item.accessibilityIdentifier = identifier
        item.accessibilityLabel = label
        return item
    }

    private func configureTestProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe") else { return }
        testProbeStack.axis = .horizontal
        testProbeStack.alignment = .center
        testProbeStack.spacing = 8
        testProbeStack.alpha = 0.02
        testProbeStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(testProbeStack)
        NSLayoutConstraint.activate([
            testProbeStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            testProbeStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistReadingProgress()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyReaderMargins()
        fitInlineImagesToTextViewport()
        if isPaginatedMode {
            let viewportSize = scrollView.bounds.size
            if viewportSize.width > 0, viewportSize.height > 0,
               viewportSize != lastPaginatedViewportSize {
                lastPaginatedViewportSize = viewportSize
                updatePaginatedTextHeight()
            }
            updatePageIndicator()
            updatePaginationProbe()
        } else {
            let viewportSize = scrollView.bounds.size
            if viewportSize.width > 0, viewportSize.height > 0,
               viewportSize != lastScrollingViewportSize {
                lastScrollingViewportSize = viewportSize
                updateScrollingTextHeight()
            }
        }
    }

    /// Keeps inline EPUB images proportional while constraining them to the
    /// actual readable viewport in both portrait and landscape orientations.
    private func fitInlineImagesToTextViewport() {
        guard !textView.isHidden, textView.bounds.width > 0 else { return }
        let availableWidth = max(
            1,
            textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        )
        let displayScale = view.window?.screen.scale ?? UIScreen.main.scale
        let viewportWidth = (availableWidth * displayScale).rounded() / displayScale
        guard lastInlineImageViewportWidth != viewportWidth else { return }
        lastInlineImageViewportWidth = viewportWidth
        guard let fitted = ReaderInlineImageLayout.fitting(
            textView.attributedText,
            maximumWidth: viewportWidth
        ) else { return }
        textView.attributedText = fitted
        if isPaginatedMode {
            DispatchQueue.main.async { [weak self] in
                self?.updatePaginatedTextHeight()
            }
        }
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, snaps a scroll destination to the nearest
    /// TextKit line-aligned page boundary. `.scrolling` mode is untouched.
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
        targetContentOffset.pointee.y = pageOffset(for: pageNumber(at: targetContentOffset.pointee.y))
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
        let anchor = captureReadingAnchor()
        ReaderProgressStore.save(
            bookId: book.id,
            chapterIndex: selectedChapter,
            offsetFraction: Double(anchor.offsetFraction),
            characterOffset: anchor.characterOffset
        )
    }

    private func captureReadingAnchor() -> ReadingAnchor {
        let scrollable = max(scrollView.contentSize.height - scrollView.bounds.height, 1)
        let fraction = min(max(scrollView.contentOffset.y / scrollable, 0), 1)
        let characterOffset: Int? = {
            guard textView.attributedText.length > 0 else { return nil }
            let point = CGPoint(x: textView.textContainerInset.left + 1,
                                y: scrollView.contentOffset.y + textView.textContainerInset.top + 1)
            let glyph = textView.layoutManager.glyphIndex(for: point, in: textView.textContainer)
            return textView.layoutManager.characterIndexForGlyph(at: glyph)
        }()
        return ReadingAnchor(offsetFraction: fraction, characterOffset: characterOffset)
    }

    private func restoreReadingAnchor(_ anchor: ReadingAnchor) {
        let scrollable = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        guard scrollable > 0 else { return }
        let target: CGFloat
        if let characterOffset = anchor.characterOffset, textView.attributedText.length > 0 {
            let safeOffset = min(characterOffset, textView.attributedText.length - 1)
            let glyph = textView.layoutManager.glyphIndexForCharacter(at: safeOffset)
            let rect = textView.layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer
            )
            let glyphOffset = max(0, rect.minY - textView.textContainerInset.top)
            target = isPaginatedMode ? pageOffset(for: pageNumber(at: glyphOffset)) : glyphOffset
        } else {
            let fractionOffset = anchor.offsetFraction * scrollable
            target = isPaginatedMode ? pageOffset(for: pageNumber(at: fractionOffset)) : fractionOffset
        }
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, target), scrollable)), animated: false)
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
            self.restoreReadingAnchor(
                ReadingAnchor(offsetFraction: CGFloat(entry.offsetFraction), characterOffset: entry.characterOffset)
            )
            self.updatePageIndicator()
        }
    }

    private func loadBook() {
        guard isViewLoaded else { return }
        loadTask?.cancel()
        loadTask = nil
        let loadingBookID = book.id
        showLoadingOverlay()
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            showUITestFixture()
            hideLoadingOverlay()
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                if book.fileType == .pdf {
                    showPDF(url)
                    hideLoadingOverlay()
                    return
                }
                let cached = await Task.detached(priority: .userInitiated) {
                    LocalFulltextCache.read(bookId: loadingBookID)
                }.value
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
                if registeredFontURLs.isEmpty {
                    registeredFontURLs = await Task.detached(priority: .userInitiated) {
                        EpubFontManager.registerFonts(from: url)
                    }.value
                }
                Task.detached(priority: .utility) {
                    LocalFulltextCache.save(payload, bookId: loadingBookID)
                }
                if cachedNeedsTitleRepair {
                    UserDefaults.standard.set(true, forKey: titleRepairKey)
                }
                guard !payload.chapters.isEmpty else {
                    throw ReaderLoadError.noReadableContent
                }
                fulltext = payload
                publishReaderChapterTitles(payload)
                if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                    selectedChapter = entry.chapterIndex
                }
                guard let selectedChapter = ReaderInitialChapter.index(
                    selectedChapter: selectedChapter,
                    chapterCount: payload.chapters.count
                ) else {
                    throw ReaderLoadError.noReadableContent
                }
                self.selectedChapter = selectedChapter
                showChapter(selectedChapter)
                restoreReadingProgressIfNeeded()
                hideLoadingOverlay()
            } catch {
                guard !Task.isCancelled, self.book.id == loadingBookID else { return }
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

    private enum ReaderLoadError: LocalizedError {
        case noReadableContent

        var errorDescription: String? {
            switch self {
            case .noReadableContent:
                L10n.string("reader.noReadableContent")
            }
        }
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
        showChapter(0)
    }

    private func showChapter(_ index: Int) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        lastInlineImageViewportWidth = nil
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
            updateTextHeightForCurrentLayout()
            repaintSavedHighlights(chapterIndex: index)
        }
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        if isUITestFixture {
            uiTestPageNumber = 1
        } else {
            uiTestPageNumber = nil
        }
        lastRenderedTextSettings = ReaderTextSettings(settings: settings)
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
        let configuration = ReaderViewportConfiguration.resolve(
            layout: settings.readerLayout,
            chromeHidden: chromeHidden,
            showsPageNumbers: settings.readerShowPageNumbers
        )
        pageIndicator.isHidden = !configuration.showsPageIndicator
        pageIndicator.alpha = configuration.showsPageIndicator ? 1 : 0
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
        let total = max(1, paginatedPageOffsets.count)
        let testPage = isUITestFixture ? uiTestPageNumber : nil
        let page = min(total, max(1, testPage ?? pageNumber(at: scrollView.contentOffset.y)))
        let value = L10n.string("reader.pageOf", page, total)
        if pageIndicator.text != value { pageIndicator.text = value }
        pageIndicator.accessibilityValue = value
    }

    private func updatePaginatedTextHeight() {
        guard isPaginatedMode, let heightConstraint = paginatedTextHeightConstraint else { return }
        let horizontalInset = textView.textContainerInset.left + textView.textContainerInset.right
        let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
        let textWidth = textView.bounds.width - horizontalInset
        let pageHeight = scrollView.bounds.height
        // Deferring until the real viewport exists prevents TextKit from
        // measuring a long chapter against its transient one-point container.
        // That stale measurement was able to leave a 40K-character chapter
        // with a single reported page after the first layout pass.
        guard textWidth > 1, pageHeight > verticalInset + 1 else { return }
        textView.textContainer.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage.length), actualCharacterRange: nil)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        heightConstraint.constant = ReaderPaginatedTextLayout.measuredContentHeight(
            layoutManager: textView.layoutManager,
            textContainer: textView.textContainer,
            verticalInset: verticalInset,
            pageHeight: pageHeight
        )
        paginatedPageOffsets = ReaderPaginatedTextLayout.pageOffsets(
            layoutManager: textView.layoutManager,
            textContainer: textView.textContainer,
            verticalInset: verticalInset,
            pageHeight: pageHeight
        )
        textView.contentSize.height = heightConstraint.constant
        view.layoutIfNeeded()
        updatePaginationProbe()
    }

    private func updateScrollingTextHeight() {
        guard !isPaginatedMode, let heightConstraint = scrollingTextHeightConstraint else { return }
        let horizontalInset = textView.textContainerInset.left + textView.textContainerInset.right
        let verticalInset = textView.textContainerInset.top + textView.textContainerInset.bottom
        let textWidth = textView.bounds.width - horizontalInset
        let viewportHeight = scrollView.bounds.height
        guard textWidth > 1, viewportHeight > 1 else { return }
        textView.textContainer.size = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
            actualCharacterRange: nil
        )
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let measuredHeight = max(
            viewportHeight,
            ceil(textView.layoutManager.usedRect(for: textView.textContainer).height) + verticalInset
        )
        heightConstraint.constant = measuredHeight
        textView.contentSize = CGSize(width: max(textView.bounds.width, 1), height: measuredHeight)
        paginatedPageOffsets = [0]
    }

    private func updateTextHeightForCurrentLayout() {
        if isPaginatedMode {
            updatePaginatedTextHeight()
        } else {
            updateScrollingTextHeight()
        }
    }

    /// Exposes visual pagination facts only in XCTest builds. UI tests need
    /// real glyph positions rather than the outer UITextView frame: the latter
    /// remains safely placed even when a sibling navigation bar overlaps text.
    private func updatePaginationProbe() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestPaginationProbe"),
              let window = view.window,
              textView.attributedText.length > 0,
              textView.layoutManager.numberOfGlyphs > 0 else { return }

        let inset = textView.textContainerInset
        let visibleRect = CGRect(
            x: 0,
            y: max(0, scrollView.contentOffset.y - inset.top),
            width: textView.textContainer.size.width,
            height: scrollView.bounds.height
        )
        let glyphRange = textView.layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textView.textContainer
        )
        guard glyphRange.length > 0 else { return }
        let firstGlyph = glyphRange.location
        let lastGlyph = NSMaxRange(glyphRange) - 1
        let firstRect = textView.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: firstGlyph, length: 1),
            in: textView.textContainer
        )
        let lastRect = textView.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: lastGlyph, length: 1),
            in: textView.textContainer
        )
        let firstPoint = textView.convert(
            CGPoint(x: firstRect.minX + inset.left, y: firstRect.minY + inset.top),
            to: window
        )
        let lastPoint = textView.convert(
            CGPoint(x: lastRect.maxX + inset.left, y: lastRect.maxY + inset.top),
            to: window
        )
        let safeTop = view.convert(
            CGPoint(x: 0, y: view.safeAreaLayoutGuide.layoutFrame.minY),
            to: window
        ).y
        paginationProbeLabel.text = [
            "first=\(textView.layoutManager.characterIndexForGlyph(at: firstGlyph))",
            "last=\(textView.layoutManager.characterIndexForGlyph(at: lastGlyph))",
            "firstY=\(Int(firstPoint.y.rounded()))",
            "lastY=\(Int(lastPoint.y.rounded()))",
            "safeTop=\(Int(safeTop.rounded()))",
            "page=\(pageNumber(at: scrollView.contentOffset.y))",
            "total=\(paginatedPageOffsets.count)",
        ].joined(separator: ";")
    }

    private func pageNumber(at offset: CGFloat) -> Int {
        guard paginatedPageOffsets.count > 1 else { return 1 }
        let epsilon: CGFloat = 0.5
        let index = paginatedPageOffsets.lastIndex(where: { $0 <= offset + epsilon }) ?? 0
        return index + 1
    }

    private func pageOffset(for page: Int) -> CGFloat {
        let index = min(max(0, page - 1), max(0, paginatedPageOffsets.count - 1))
        return paginatedPageOffsets[index]
    }

    @objc private func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let pointInView = gesture.location(in: view)
        switch ReaderTapAction.resolve(
            point: pointInView,
            in: view.bounds,
            isPaginated: isPaginatedMode
        ) {
        case .toggleChrome:
            toggleChromeVisibility()
        case let .turnPage(forward):
            navigatePage(forward: forward)
        case .none:
            return
        }
    }

    @objc private func toggleChromeVisibility() {
        chromeHidden.toggle()
        let shouldShow = !chromeHidden
        let shouldShowPageIndicator = shouldShow && isPaginatedMode && settings.readerShowPageNumbers
        if shouldShowPageIndicator {
            pageIndicator.isHidden = false
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
            self.pageIndicator.alpha = shouldShowPageIndicator ? alpha : 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !shouldShowPageIndicator {
                self.pageIndicator.isHidden = true
            }
            UIAccessibility.post(notification: .layoutChanged, argument: self.textView)
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
            self?.scheduleReaderSettingsUpdate()
        }
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func scheduleReaderSettingsUpdate() {
        guard fulltext != nil else { return }
        settingsUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyReaderSettingsImmediately()
        }
        settingsUpdateWorkItem = workItem
        // UISlider can emit many values in one drag. Coalesce them to a
        // display-friendly cadence so typography updates stay live without
        // making the control itself lose its gesture.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }

    private func applyReaderSettingsImmediately() {
        let readingAnchor = captureReadingAnchor()
        let nextTextSettings = ReaderTextSettings(settings: settings)
        let needsTextRerender = lastRenderedTextSettings != nextTextSettings
        let colors = settings.readerTheme.previewColors
        view.backgroundColor = colors.background
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        pageIndicator.textColor = colors.foreground.withAlphaComponent(0.7)
        applyReaderLayoutMode()
        applyReaderMargins()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if needsTextRerender {
            showChapter(selectedChapter)
        } else {
            updateTextHeightForCurrentLayout()
        }
        view.layoutIfNeeded()
        restoreReadingAnchor(readingAnchor)
        updatePageIndicator()
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pageTap else { return true }
        let point = touch.location(in: textView)
        return !isLink(at: point)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return isPaginatedMode && abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 20
    }

    private func isLink(at point: CGPoint) -> Bool {
        guard textView.bounds.contains(point), let attributed = textView.attributedText,
              attributed.length > 0 else { return false }
        let containerPoint = CGPoint(
            x: point.x - textView.textContainerInset.left,
            y: point.y - textView.textContainerInset.top
        )
        let glyph = textView.layoutManager.glyphIndex(
            for: containerPoint,
            in: textView.textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < textView.layoutManager.numberOfGlyphs else { return false }
        let glyphRange = NSRange(location: glyph, length: 1)
        guard textView.layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textView.textContainer
        ).contains(containerPoint) else { return false }
        let character = textView.layoutManager.characterIndexForGlyph(at: glyph)
        guard character < attributed.length else { return false }
        return attributed.attribute(.link, at: character, effectiveRange: nil) != nil
    }

    private var measuredPageCount: Int {
        max(1, paginatedPageOffsets.count)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isPaginatedMode {
            updatePageIndicator()
        }
        guard ProcessInfo.processInfo.arguments.contains("-uiTestReaderLayout") else { return }
        let offset = scrollView === textView ? textView.contentOffset.y : scrollView.contentOffset.y
        textView.accessibilityValue = "offset=\(Int(offset.rounded()))"
        scrollProbeLabel.text = "offset=\(Int(offset.rounded()))"
        updatePaginationProbe()
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
        guard !isPageTransitioning else { return }
        guard let fulltext, fulltext.chapters[safe: selectedChapter] != nil else { return }
        isPageTransitioning = true
        view.layoutIfNeeded()
        let estimatedTotal = measuredPageCount
        let current = pageNumber(at: scrollView.contentOffset.y)
        if forward, current >= estimatedTotal, selectedChapter + 1 < fulltext.chapters.count {
            persistReadingProgress(); selectedChapter += 1; showChapter(selectedChapter)
            scrollView.setContentOffset(.zero, animated: false); updatePageIndicator()
            finishChapterTransition(); return
        }
        if !forward, current <= 1, selectedChapter > 0 {
            persistReadingProgress(); selectedChapter -= 1; showChapter(selectedChapter)
            let previousTotal = measuredPageCount
            if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
                uiTestPageNumber = previousTotal
            }
            scrollView.setContentOffset(CGPoint(x: 0, y: pageOffset(for: previousTotal)), animated: false)
            updatePageIndicator(); finishChapterTransition(); return
        }
        if (forward && current >= estimatedTotal) || (!forward && current <= 1) {
            isPageTransitioning = false
            return
        }
        let next = min(estimatedTotal, max(1, current + (forward ? 1 : -1)))
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            uiTestPageNumber = next
        }
        setPageOffset(CGPoint(x: 0, y: pageOffset(for: next)), forward: forward)
        updatePageIndicator(); persistReadingProgress()
    }

    private func finishChapterTransition() {
        // Chapter rendering and layout can be expensive for EPUBs with many
        // short sections. Keep the input serialized for one run-loop turn so
        // another edge tap cannot observe half-rendered text metrics.
        DispatchQueue.main.async { [weak self] in
            self?.isPageTransitioning = false
        }
    }

    private func setPageOffset(_ offset: CGPoint, forward: Bool) {
        switch settings.pageTurnStyle {
        case .none:
            scrollView.setContentOffset(offset, animated: false)
            isPageTransitioning = false
        case .slide, .flip:
            // Paginated mode is a page transition, not a vertical scroll.
            // Keep the scroll view as a layout container, move its offset
            // synchronously, and animate a snapshot horizontally. This also
            // prevents UIKit from exposing the intermediate vertical offset
            // when the reader is opened with everything else hidden.
            let oldPage = scrollView.snapshotView(afterScreenUpdates: false)
            let frame = scrollView.convert(scrollView.bounds, to: view)
            scrollView.setContentOffset(offset, animated: false)
            guard let oldPage else {
                isPageTransitioning = false
                return
            }
            oldPage.frame = frame
            view.addSubview(oldPage)
            scrollView.transform = CGAffineTransform(translationX: forward ? frame.width : -frame.width, y: 0)
            UIView.animate(withDuration: 0.35, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                oldPage.transform = CGAffineTransform(translationX: forward ? -frame.width : frame.width, y: 0)
                self.scrollView.transform = .identity
            } completion: { _ in
                oldPage.removeFromSuperview()
                self.isPageTransitioning = false
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

    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        guard let fulltext, let chapter = fulltext.chapters[safe: selectedChapter],
              characterRange.location != NSNotFound,
              NSMaxRange(characterRange) <= textView.attributedText.length else {
            return false
        }
        let linkedText = (textView.attributedText.string as NSString).substring(with: characterRange)
        switch ReaderLinkResolver.destination(
            for: url,
            linkText: linkedText,
            currentChapter: chapter,
            chapters: fulltext.chapters
        ) {
        case .chapter(let index):
            guard fulltext.chapters.indices.contains(index) else { return false }
            persistReadingProgress()
            selectedChapter = index
            showChapter(index)
            scrollView.setContentOffset(.zero, animated: false)
            return false
        case .footnote(let footnote):
            let sheet = FootnotesSheetController(footnotes: [footnote])
            present(UINavigationController(rootViewController: sheet), animated: true)
            return false
        case .external:
            return true
        case .unresolved:
            return false
        }
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

enum ReaderTapAction: Equatable {
    case toggleChrome
    case turnPage(forward: Bool)
    case none

    static func resolve(point: CGPoint, in bounds: CGRect, isPaginated: Bool) -> ReaderTapAction {
        guard bounds.contains(point) else { return .none }
        let centre = bounds.insetBy(
            dx: bounds.width * 0.3,
            dy: bounds.height * 0.3
        )
        if centre.contains(point) {
            return .toggleChrome
        }
        guard isPaginated else { return .none }
        return .turnPage(forward: point.x >= bounds.midX)
    }
}

struct ReaderViewportConfiguration: Equatable {
    let allowsVerticalScrolling: Bool
    let allowsChapterSwipes: Bool
    let usesPaginatedTextHeight: Bool
    let showsPageIndicator: Bool

    static func resolve(
        layout: ReaderLayout,
        chromeHidden: Bool,
        showsPageNumbers: Bool
    ) -> ReaderViewportConfiguration {
        let paginated = layout == .paginated
        return ReaderViewportConfiguration(
            allowsVerticalScrolling: !paginated,
            allowsChapterSwipes: !paginated,
            usesPaginatedTextHeight: paginated,
            showsPageIndicator: paginated && !chromeHidden && showsPageNumbers
        )
    }
}

private struct ReaderTextSettings: Equatable {
    let fontSize: Int
    let fontFamily: ReaderFontFamily
    let theme: ReaderTheme
    let lineSpacing: Double
    let alignment: ReaderTextAlignment
    let overridesFontFamily: Bool
    let overridesFontSize: Bool
    let overridesColours: Bool
    let boldOverride: Bool
    let suppressesItalic: Bool
    let letterSpacing: Double
    let wordSpacing: Double

    init(settings: AppSettings) {
        fontSize = settings.readerFontSize
        fontFamily = settings.readerFontFamily
        theme = settings.readerTheme
        lineSpacing = settings.readerLineSpacing
        alignment = settings.readerTextAlignment
        overridesFontFamily = settings.readerOverrideFontFamily
        overridesFontSize = settings.readerOverrideFontSize
        overridesColours = settings.readerOverrideColours
        boldOverride = settings.readerBoldOverride
        suppressesItalic = settings.readerSuppressItalic
        letterSpacing = settings.readerLetterSpacing
        wordSpacing = settings.readerWordSpacing
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
