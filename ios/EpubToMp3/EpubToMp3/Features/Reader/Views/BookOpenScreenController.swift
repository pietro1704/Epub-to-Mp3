#if os(iOS)
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BookOpenScreenController: UIViewController, UIDocumentPickerDelegate, UIScrollViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// The current rendered chapter for each of the two warm books. NSCache
    /// releases these automatically under memory pressure, while avoiding a
    /// repeat HTML/CSS render when the listener returns to a book in-process.
    private final class WarmRenderedChapter: NSObject {
        let chapterIndex: Int
        let settings: ReaderTextSettings
        let attributedText: NSAttributedString

        init(chapterIndex: Int, settings: ReaderTextSettings, attributedText: NSAttributedString) {
            self.chapterIndex = chapterIndex
            self.settings = settings
            self.attributedText = attributedText
        }
    }

    private static let warmRenderedChapters: NSCache<NSString, WarmRenderedChapter> = {
        let cache = NSCache<NSString, WarmRenderedChapter>()
        cache.countLimit = 2
        cache.name = "com.pietrocode.epubtomp3.warm-reader-chapters"
        return cache
    }()

    private var book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let bookmarkStore: BookmarkStore
    private let player: AudioPlayer
    private let textView = ReaderTextViewFactory.make()
    private let comicPageImageView = UIImageView()
    private lazy var contentSurface = ReaderContentSurface(
        readerView: view,
        scrollView: scrollView,
        textView: textView,
        comicPageImageView: comicPageImageView
    )
    private let scrollView = UIScrollView()
    private let pageIndicator = UILabel()
    private let pageOverflowGuard = UIView()
    private let pageUnderflowGuard = UIView()
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
    private var paginatedTextHeightConstraint: NSLayoutConstraint!
    private var scrollingTextHeightConstraint: NSLayoutConstraint!
    private var scrollTopToSafeArea: NSLayoutConstraint!
    private var scrollTopToRoot: NSLayoutConstraint!
    private var scrollBottomToPageIndicator: NSLayoutConstraint!
    private var scrollBottomToSafeArea: NSLayoutConstraint!
    private var scrollBottomToRoot: NSLayoutConstraint!
    private var paginatedPageOffsets: [CGFloat] = [0]
    /// The single glyph-aware pagination decision for the final viewport.
    /// Keep the legacy offset array while callers migrate, but never derive a
    /// second set of boundaries from the controller's own TextKit traversal.
    private var paginatedLayoutResult: ReaderPaginatedTextLayout.Result?
    private var forcesScrollingForOversizedFragment = false
    private var lastPaginatedViewportSize: CGSize = .zero
    private var lastScrollingViewportSize: CGSize = .zero
    private var settingsUpdateWorkItem: DispatchWorkItem?
    private var lastRenderedTextSettings: ReaderTextSettings?
    private var uiTestPageNumber: Int?
    private lazy var textViewport = ReaderTextViewport(
        textView: textView,
        scrollView: scrollView,
        hostView: view,
        pageIndicator: pageIndicator,
        overflowGuard: pageOverflowGuard,
        underflowGuard: pageUnderflowGuard,
        paginatedHeight: paginatedTextHeightConstraint,
        scrollingHeight: scrollingTextHeightConstraint
    )
    /// TextKit must not measure a chapter against the temporary one-point
    /// viewport that UIKit can expose while the host swaps loading chrome.
    /// `viewDidLayoutSubviews()` performs one coalesced measurement once the
    /// reader has its final bounds.
    private var needsTextLayoutRefresh = false
    private var activeLoadingID: UUID?
    private var pendingLoadingCompletionID: UUID?
    private var activeBookOpenJourneyID: UUID?
    private var pendingPDFPageJourneyID: UUID?
    private var firstPDFPageReadyJourneyID: UUID?
    private var controlsReadyJourneyID: UUID?
    private var isDeferringReaderGestures = false
    private var isLoadingContent = false
    /// Prevents overlapping page renders/snapshots when the user taps the
    /// reader edges repeatedly while a page transition is still running.
    private var isPageTransitioning = false

    private var isPaginatedMode: Bool {
        return settings.readerLayout == .paginated && !forcesScrollingForOversizedFragment
    }

    private var isUITestFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestFixture")
    }

    private struct ReadingAnchor {
        let offsetFraction: CGFloat
        let characterOffset: Int?
        /// The chrome transition only changes viewport height. Preserve its
        /// exact vertical origin instead of reinterpreting it as a different
        /// paginated boundary.
        let viewportOffset: CGFloat?

        init(offsetFraction: CGFloat, characterOffset: Int?, viewportOffset: CGFloat? = nil) {
            self.offsetFraction = offsetFraction
            self.characterOffset = characterOffset
            self.viewportOffset = viewportOffset
        }
    }

    /// A paginated page boundary depends on the complete viewport geometry.
    /// Keep the exact offset a reader saw for each chrome state so an
    /// on/off round trip returns to that same page instead of re-rounding the
    /// passage to a nearby page boundary on every reflow.
    private struct ViewportAnchorKey: Hashable {
        let chromeHidden: Bool
        let width: Int
        let height: Int
    }

    private var pendingViewportAnchor: ReadingAnchor?
    private var rawViewportOffsets: [ViewportAnchorKey: CGFloat] = [:]
    private var chromeVisibleRawViewportOffset: CGFloat?
    private var rememberedViewportOffsets: [ViewportAnchorKey: (character: Int, offset: CGFloat)] = [:]
    /// Page offsets are invalid while the host is animating a chrome-driven
    /// viewport resize. Serializing input avoids splitting TextKit lines.
    private var isViewportTransitioning = false
    private var lastInlineImageViewportWidth: CGFloat?
    /// Guards against re-seeking the scroll position on every manual
    /// chapter tap — restoration only makes sense once, right after the
    /// book is (re)loaded.
    private var hasRestoredInitialPosition = false

    /// Reports whether the book is currently loading (parsing/fetching
    /// fulltext), so the host screen (`MainReaderScreenController`) can
    /// hide chrome like the "Ouvir" button until content is ready.
    var onLoadStateChanged: ((Bool) -> Void)?

    /// The host owns presentation state; it only needs this content fact
    /// while it synchronizes the initial loading cover into its final viewport.
    var isLoadingBookContent: Bool { isLoadingContent }

    /// Hosts apply explicit presentation snapshots through
    /// `applyChromeVisibility`. The content surface only requests a state
    /// reset after loading or a user-driven toggle; it never derives the
    /// next state from its local layout cache.
    var onChromeVisibilityRequested: ((Bool) -> Void)?

    /// The reader's in-memory chapter is more current than persisted progress
    /// while the user is turning pages, so playback scheduling uses this
    /// value to synthesize the chapter currently on screen first.
    var currentReaderChapterIndex: Int { selectedChapter }

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
        pageIndicator.isAccessibilityElement = true
        pageIndicator.isHidden = !isPaginatedMode || !settings.readerShowPageNumbers
        pageIndicator.textAlignment = .center
        pageIndicator.textColor = .secondaryLabel
        pageIndicator.font = .preferredFont(forTextStyle: .footnote)
        pageIndicator.text = L10n.string("reader.pageOf", 1, 1)
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
        // The viewport is constrained to the safe area explicitly. Automatic
        // scroll-view adjustment applies a second inset during chrome
        // transitions and can place the first line above that safe area.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        pageTap.delegate = self
        pageTap.cancelsTouchesInView = false
        // A text view owns several private single-tap recognizers. Make them
        // wait for the reader gesture so a repeated centre tap can always
        // restore chrome. `shouldReceive` rejects links, allowing their
        // native recognizer to proceed without delay.
        for gesture in textView.gestureRecognizers ?? [] where gesture is UITapGestureRecognizer {
            gesture.require(toFail: pageTap)
        }
        // Own reader gestures on the scrolling reading surface. UIKit only
        // arbitrates a descendant touch against recognizers installed on its
        // scroll-view ancestors; placing this on the outer controller view
        // lets UITextView's private taps swallow a centre tap after reflow.
        scrollView.addGestureRecognizer(pageTap)
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
            pageIndicator.heightAnchor.constraint(greaterThanOrEqualToConstant: pageIndicator.font.lineHeight),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        scrollView.accessibilityIdentifier = "reader.viewport"
        pageOverflowGuard.isUserInteractionEnabled = false
        pageOverflowGuard.accessibilityElementsHidden = true
        pageOverflowGuard.backgroundColor = settings.readerTheme.previewColors.background
        pageOverflowGuard.isHidden = true
        view.addSubview(pageOverflowGuard)
        pageUnderflowGuard.isUserInteractionEnabled = false
        pageUnderflowGuard.accessibilityElementsHidden = true
        pageUnderflowGuard.backgroundColor = settings.readerTheme.previewColors.background
        pageUnderflowGuard.isHidden = true
        view.addSubview(pageUnderflowGuard)
        view.bringSubviewToFront(pageIndicator)
        scrollTopToSafeArea = scrollView.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor,
            constant: 8
        )
        scrollTopToRoot = scrollView.topAnchor.constraint(equalTo: view.topAnchor)
        scrollBottomToPageIndicator = scrollView.bottomAnchor.constraint(equalTo: pageIndicator.topAnchor, constant: -8)
        scrollBottomToSafeArea = scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        scrollBottomToRoot = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        loadingCoverView.accessibilityIdentifier = "reader.loadingCover"
        loadingCoverView.isAccessibilityElement = true
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
        // A process-warm payload is rendered before `loadBook()` presents a
        // loading state. Keep the overlay hidden by default so that first
        // frame is the saved chapter rather than a flash of the cover.
        loadingContainer.isHidden = true
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
        let preferredLoadingCoverWidth = loadingCoverView.widthAnchor.constraint(
            equalTo: loadingContainer.safeAreaLayoutGuide.widthAnchor,
            multiplier: ReaderLoadingLayoutMetrics.preferredCoverWidthFraction
        )
        preferredLoadingCoverWidth.priority = .defaultHigh
        let loadingCoverAspectRatio = loadingCoverView.heightAnchor.constraint(
            equalTo: loadingCoverView.widthAnchor,
            multiplier: ReaderLoadingLayoutMetrics.coverAspectRatio
        )
        loadingCoverAspectRatio.priority = .required
        let preferredLoadingTop = loadingStack.topAnchor.constraint(
            equalTo: loadingContainer.safeAreaLayoutGuide.topAnchor,
            constant: ReaderLoadingLayoutMetrics.preferredTopSpacing
        )
        preferredLoadingTop.priority = .defaultHigh
        let fallbackLoadingCenter = loadingStack.centerYAnchor.constraint(
            equalTo: loadingContainer.centerYAnchor
        )
        fallbackLoadingCenter.priority = .defaultLow
        NSLayoutConstraint.activate([
            loadingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            loadingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingStack.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            preferredLoadingTop,
            fallbackLoadingCenter,
            loadingStack.topAnchor.constraint(
                greaterThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.topAnchor,
                constant: ReaderLoadingLayoutMetrics.minimumVerticalMargin
            ),
            loadingStack.bottomAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.bottomAnchor,
                constant: -ReaderLoadingLayoutMetrics.minimumVerticalMargin
            ),
            loadingMarginLeading,
            loadingMarginTrailing,
            loadingCoverView.widthAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.widthAnchor,
                multiplier: ReaderLoadingLayoutMetrics.maximumCoverWidthFraction
            ),
            loadingCoverView.heightAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.heightAnchor,
                multiplier: ReaderLoadingLayoutMetrics.maximumCoverHeightFraction
            ),
            preferredLoadingCoverWidth,
            loadingCoverAspectRatio,
        ])

        contentSurface.install()
        contentSurface.onPDFPageReady = { [weak self] wasNormalized in
            self?.recordFirstPDFPage(wasNormalized: wasNormalized)
        }
        paginatedTextHeightConstraint = contentSurface.paginatedTextHeightConstraint
        scrollingTextHeightConstraint = contentSurface.scrollingTextHeightConstraint
        applyReaderLayoutMode()
    }

    private func applyReaderLayoutMode() {
        let configuration = ReaderViewportConfiguration.resolve(
            layout: settings.readerLayout,
            chromeHidden: chromeHidden,
            showsPageNumbers: settings.readerShowPageNumbers
        )
        let isDisplayingImageChapter = contentSurface.isDisplayingComic
        let allowsTextScrolling = configuration.allowsVerticalScrolling && !isDisplayingImageChapter
        scrollView.isScrollEnabled = allowsTextScrolling
        scrollView.panGestureRecognizer.isEnabled = allowsTextScrolling
        scrollView.alwaysBounceVertical = allowsTextScrolling
        scrollView.alwaysBounceHorizontal = false
        textView.isScrollEnabled = false
        textView.panGestureRecognizer.isEnabled = false
        textView.textContainer.widthTracksTextView = !configuration.usesPaginatedTextHeight
        textView.textContainer.heightTracksTextView = false
        paginatedTextHeightConstraint.isActive = !isDisplayingImageChapter && configuration.usesPaginatedTextHeight
        scrollingTextHeightConstraint.isActive = !isDisplayingImageChapter && !configuration.usesPaginatedTextHeight
        // Text container padding already provides the reading gutter. Keep
        // the scroll viewport on the safe-area edge in both chrome states so
        // the first line can never be clipped by an outer 8pt gap.
        scrollTopToSafeArea.constant = 0
        scrollBottomToPageIndicator.constant = -8
        scrollBottomToSafeArea.constant = chromeHidden ? 0 : -8
        NSLayoutConstraint.deactivate([
            scrollTopToSafeArea,
            scrollTopToRoot,
            scrollBottomToPageIndicator,
            scrollBottomToSafeArea,
            scrollBottomToRoot,
        ])
        if configuration.usesScreenEdges {
            NSLayoutConstraint.activate([scrollTopToRoot, scrollBottomToRoot])
        } else if configuration.showsPageIndicator {
            NSLayoutConstraint.activate([scrollTopToSafeArea, scrollBottomToPageIndicator])
        } else {
            NSLayoutConstraint.activate([scrollTopToSafeArea, scrollBottomToSafeArea])
        }
        forwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        backwardChapterSwipe.isEnabled = configuration.allowsChapterSwipes
        pageIndicator.isHidden = !configuration.showsPageIndicator
        pageIndicator.alpha = configuration.showsPageIndicator ? 1 : 0
        lastPaginatedViewportSize = .zero
        lastScrollingViewportSize = .zero
    }

    /// Applies the root-owned chrome snapshot locally. The reader never
    /// chooses this state: it only updates its own safe-area constraints.
    @discardableResult
    func applyChromeVisibility(_ isHidden: Bool) -> Bool {
        guard chromeHidden != isHidden else { return false }
        chromeHidden = isHidden
        applyReaderLayoutMode()
        return true
    }

    private func applyReaderMargins() {
        let margin = CGFloat(ReaderLayoutMetrics.clampedMargin(settings.readerMargin))
        contentSurface.setTextMargins(margin)
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
               (needsTextLayoutRefresh || viewportSize != lastPaginatedViewportSize) {
                if updatePaginatedTextHeight() {
                    lastPaginatedViewportSize = viewportSize
                    needsTextLayoutRefresh = false
                }
            }
            updatePageIndicator()
            updatePageOverflowGuard()
            updatePaginationProbe()
        } else {
            pageOverflowGuard.isHidden = true
            pageUnderflowGuard.isHidden = true
            let viewportSize = scrollView.bounds.size
            if viewportSize.width > 0, viewportSize.height > 0,
               (needsTextLayoutRefresh || viewportSize != lastScrollingViewportSize) {
                if updateScrollingTextHeight() {
                    lastScrollingViewportSize = viewportSize
                    needsTextLayoutRefresh = false
                }
            }
        }
        restorePendingViewportAnchorIfNeeded()
        completeLoadingAfterStableTextLayoutIfNeeded()
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
        requestTextLayoutRefresh()
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, snaps a scroll destination to the nearest
    /// TextKit line-aligned page boundary. `.scrolling` mode is untouched.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard canNavigateReader, settings.readerLayout == .paginated else { return }
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
        rememberViewportOffset(for: anchor)
        ReaderProgressStore.save(
            bookId: book.id,
            chapterIndex: selectedChapter,
            offsetFraction: Double(anchor.offsetFraction),
            characterOffset: anchor.characterOffset
        )
    }

    private func captureReadingAnchor() -> ReadingAnchor {
        let scrollable = max(
            scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height,
            1
        )
        // A chrome restore can intentionally start on a TextKit line that is
        // not one of the global page-turn boundaries. Replacing that visible
        // offset with the preceding global boundary makes every subsequent
        // chrome tap capture an earlier passage and progressively walk the
        // reader backwards.
        let visibleOffset = scrollView.contentOffset.y
        let fraction = min(max(visibleOffset / scrollable, 0), 1)
        let characterOffset: Int? = { () -> Int? in
            guard textView.attributedText.length > 0 else { return nil }
            if isPaginatedMode {
                // Capture the first complete line at or below the actual
                // viewport edge. The viewport may have a line-based restore
                // offset rather than a global page-turn boundary.
                let fullRange = textView.layoutManager.glyphRange(for: textView.textContainer)
                var character: Int?
                let epsilon: CGFloat = 0.5
                textView.layoutManager.enumerateLineFragments(forGlyphRange: fullRange) {
                    lineRect, _, _, glyphRange, stop in
                    guard glyphRange.length > 0,
                          lineRect.minY >= visibleOffset - self.textView.textContainerInset.top - epsilon else { return }
                    character = self.textView.layoutManager.characterIndexForGlyph(at: glyphRange.location)
                    stop.pointee = true
                }
                return character
            }
            let visibleRect = CGRect(
                x: 0,
                y: max(0, visibleOffset),
                width: textView.textContainer.size.width,
                height: scrollView.bounds.height
            )
            let glyphRange = textView.layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textView.textContainer
            )
            guard glyphRange.length > 0 else { return nil }
            return textView.layoutManager.characterIndexForGlyph(at: glyphRange.location)
        }()
        return ReadingAnchor(
            offsetFraction: fraction,
            characterOffset: characterOffset,
            viewportOffset: visibleOffset
        )
    }

    private func restoreReadingAnchor(_ anchor: ReadingAnchor, preservingViewportOffset: Bool = false) {
        let scrollable = max(
            scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height,
            0
        )
        guard scrollable > 0 else { return }
        let candidate: CGFloat
        if preservingViewportOffset, let viewportOffset = anchor.viewportOffset {
            candidate = viewportOffset
        } else if let characterOffset = anchor.characterOffset, textView.attributedText.length > 0 {
            let safeOffset = min(characterOffset, textView.attributedText.length - 1)
            let glyph = textView.layoutManager.glyphIndexForCharacter(at: safeOffset)
            let lineRect = textView.layoutManager.lineFragmentRect(
                forGlyphAt: glyph,
                effectiveRange: nil
            )
            // A glyph's bounding box excludes the line's leading. Restoring
            // to that smaller rect leaves the top of the first rendered line
            // above the viewport after a chrome reflow. Use the complete
            // TextKit line fragment, preserving the passage without clipping.
            candidate = max(0, lineRect.minY + textView.textContainerInset.top)
        } else {
            candidate = anchor.offsetFraction * scrollable
        }
        // A saved glyph anchor is not necessarily a valid paginated page
        // boundary. Snap it to the layout-generated page start; restoring to
        // an arbitrary line only protects the top edge and can crop the last
        // visible line after chrome or safe-area reflow.
        let target: CGFloat
        if !preservingViewportOffset,
           isPaginatedMode,
           let characterOffset = anchor.characterOffset,
           let remembered = rememberedViewportOffsets[viewportAnchorKey()],
           remembered.character == characterOffset {
            // This exact chrome geometry has already displayed this passage.
            // Reusing its measured page start makes a chrome round trip
            // perfectly reversible instead of progressively rounding back.
            target = remembered.offset
        } else {
            // The visible TextKit line is the reading anchor. Global page
            // boundaries differ between chrome geometries, so rounding this
            // line down moves backwards and rounding it up moves forwards on
            // every toggle. Keep the line itself at the viewport top; the
            // glyph-aware overflow guard suppresses only an incomplete final
            // line, never the anchored passage.
            target = candidate
        }
        let appliedOffset = min(max(0, target), scrollable)
        scrollView.setContentOffset(CGPoint(x: 0, y: appliedOffset), animated: false)
        // `target` may be the preceding canonical boundary when a line that
        // was first in the old viewport no longer starts a page in the new
        // geometry. Cache the anchor that is actually on screen, never the
        // requested one: associating the old character with that preceding
        // offset poisons later chrome round trips and walks the reader back.
        rememberViewportOffset(for: captureReadingAnchor())
        // `setContentOffset` does not reliably produce a layout pass. Refresh
        // the XCTest-only probe after the restore so it reports the page that
        // is actually on screen rather than the page from before reflow.
        updatePaginationProbe()
    }

    private func viewportAnchorKey() -> ViewportAnchorKey {
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        return ViewportAnchorKey(
            chromeHidden: chromeHidden,
            width: Int((scrollView.bounds.width * scale).rounded()),
            height: Int((scrollView.bounds.height * scale).rounded())
        )
    }

    private func rememberViewportOffset(for anchor: ReadingAnchor) {
        guard isPaginatedMode,
              let character = anchor.characterOffset,
              scrollView.bounds.width > 0,
              scrollView.bounds.height > 0 else { return }
        rememberedViewportOffsets[viewportAnchorKey()] = (
            character: character,
            offset: pageOffset(for: pageNumber(at: scrollView.contentOffset.y))
        )
    }

    /// The parent reader changes its top and bottom anchors while entering
    /// immersive mode. Capture the current glyph before that reflow and
    /// restore it after TextKit has measured the larger viewport.
    func prepareForViewportTransition() {
        guard loadingContainer.isHidden,
              scrollView.bounds.height > 0 else { return }
        // Both the reader and its host prepare the same constraint change.
        // The host call happens after the child has swapped its local
        // constraints, when UIKit may already have clamped the scroll view.
        // Preserve the first (pre-mutation) anchor for this transaction.
        // The root transition coordinator has already deduplicated requests.
        // A stale child anchor must never suppress the fresh raw capture for a
        // new chrome transaction; doing so restores an earlier clamped page.
        pendingViewportAnchor = captureReadingAnchor()
        rawViewportOffsets[viewportAnchorKey()] = scrollView.contentOffset.y
        if !chromeHidden {
            chromeVisibleRawViewportOffset = scrollView.contentOffset.y
        }
        isViewportTransitioning = true
        requestTextLayoutRefresh()
    }

    private func restorePendingViewportAnchorIfNeeded(preservingViewportOffset: Bool = false) {
        guard let anchor = pendingViewportAnchor,
              scrollView.bounds.height > 0,
              !isViewportTransitioning else { return }
        pendingViewportAnchor = nil
        restoreReadingAnchor(anchor, preservingViewportOffset: preservingViewportOffset)
        updatePageIndicator()
    }

    /// The parent invokes this after its navigation-bar animation reaches
    /// final geometry. Only then are the current page offsets safe to use.
    func completeViewportTransition() {
        guard isViewportTransitioning else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        updateTextHeightForCurrentLayout()
        // The root has committed its constraints, but UIKit can still expose
        // the previous child-scroll bounds until the next main-loop layout.
        // Restoring a raw offset against that stale height clamps it and makes
        // a later chrome round trip walk backward.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewportTransitioning else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.updateTextHeightForCurrentLayout()
            self.finishViewportTransitionRestore()
        }
    }

    private func finishViewportTransitionRestore() {
        if let anchor = pendingViewportAnchor,
           let rawOffset = !chromeHidden
                ? chromeVisibleRawViewportOffset
                : rawViewportOffsets[viewportAnchorKey()]
                    ?? rawViewportOffsets.first(where: { $0.key.chromeHidden == chromeHidden })?.value {
            pendingViewportAnchor = ReadingAnchor(
                offsetFraction: anchor.offsetFraction,
                characterOffset: anchor.characterOffset,
                viewportOffset: rawOffset
            )
        }
        isViewportTransitioning = false
        restorePendingViewportAnchorIfNeeded(preservingViewportOffset: true)
        UIAccessibility.post(notification: .layoutChanged, argument: textView)
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
        cancelActiveBookOpenJourney()
        let loadingBookID = book.id
        let loadingID = UUID()
        activeLoadingID = loadingID
        pendingLoadingCompletionID = nil
        let journeyID = LatencyObservationStore.shared.beginBookOpen(
            documentKind: Self.documentKind(for: book)
        )
        activeBookOpenJourneyID = journeyID

        // A process-warm book already has the reader payload and fonts from
        // its last visit. Paint its saved chapter synchronously, before the
        // first loading frame, instead of reopening the security-scoped EPUB.
        if let warmPayload = LocalFulltextCache.inMemoryPayload(bookId: loadingBookID),
           !warmPayload.chapters.isEmpty {
            LatencyObservationStore.shared.classifyCache(.inMemoryWarm, for: journeyID)
            registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
            displayPreparedPayload(warmPayload, loadingID: loadingID)
            return
        }

        showLoadingOverlay()
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
            loadUITestFixture(after: uiTestLoadingDelay)
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cached = await Task.detached(priority: .userInitiated) {
                    LocalFulltextCache.read(bookId: loadingBookID)
                }.value
                let payload: EbookFulltext
                let cachedNeedsTitleRepair = cached?.chapters.contains(where: { $0.hasGeneratedName }) == true
                let cachedHasReadableContent = cached?.chapters.contains(where: { $0.hasReadableContent }) == true
                let titleRepairKey = "reader.titleRepairAttempted.\(book.id)"
                let shouldRepairCachedTitles = cachedNeedsTitleRepair
                    && !UserDefaults.standard.bool(forKey: titleRepairKey)
                if let cached, !shouldRepairCachedTitles, cachedHasReadableContent {
                    LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
                    payload = cached
                } else {
                    LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
                    let url = try await library.openBookFileAsync(id: book.id)
                    if book.fileType == .pdf {
                        pendingPDFPageJourneyID = journeyID
                        showPDF(url)
                        guard self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                        hideLoadingOverlay()
                        return
                    }
                    if book.fileType.requiresServerConversion {
                        guard let baseURL = settings.resolvedBaseURL else {
                            throw APIError.invalidBaseURL
                        }
                        let client = APIClient(baseURL: baseURL)
                        let uploadID = try await client.uploadBook(at: url)
                        payload = try await client.fetchUploadedFulltext(uploadID: uploadID)
                    } else {
                        payload = try await PythonBridge.shared.parseEpub(at: url, bookId: book.id)
                    }
                    if registeredFontURLs.isEmpty {
                        registeredFontURLs = await Task.detached(priority: .userInitiated) {
                            EpubFontManager.registerFonts(from: url, bookID: loadingBookID)
                        }.value
                    }
                }
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                if registeredFontURLs.isEmpty {
                    registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
                }
                Task.detached(priority: .utility) {
                    LocalFulltextCache.save(payload, bookId: loadingBookID)
                }
                if cachedNeedsTitleRepair {
                    UserDefaults.standard.set(true, forKey: titleRepairKey)
                }
                displayPreparedPayload(payload, loadingID: loadingID)
            } catch {
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                textView.text = ""
                showLoadingError(error.localizedDescription)
            }
        }
    }

    /// Applies prepared reader content after either a warm-cache hit or a
    /// cold parse. Keeping this path shared makes saved-position restoration
    /// identical in both cases while allowing the warm path to skip file I/O.
    private func displayPreparedPayload(_ payload: EbookFulltext, loadingID: UUID) {
        guard isCurrentLoad(loadingID, bookID: book.id) else { return }
        guard !payload.chapters.isEmpty else {
            showLoadingError(ReaderLoadError.noReadableContent.localizedDescription)
            return
        }
        fulltext = payload
        LocalFulltextCache.recordWarmOpen(bookId: book.id)
        publishReaderChapterTitles(payload)
        if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
            selectedChapter = entry.chapterIndex
        } else if !hasRestoredInitialPosition, selectedChapter == 0 {
            // Many EPUBs put a cover, title page, and contents page before
            // the first readable passage. Saved progress still wins.
            selectedChapter = ReaderInitialChapter.firstSubstantiveIndex(in: payload.chapters)
        }
        guard let selectedChapter = ReaderInitialChapter.index(
            selectedChapter: selectedChapter,
            chapterCount: payload.chapters.count
        ) else {
            showLoadingError(ReaderLoadError.noReadableContent.localizedDescription)
            return
        }
        self.selectedChapter = selectedChapter
        showChapter(selectedChapter)
        finishLoadingAfterStableTextLayout(loadingID)
    }

    deinit {
        loadTask?.cancel()
        cancelActiveBookOpenJourney()
    }

    /// Cover + spinner only — no TOC, footnotes, search, or "loading" text
    /// wall. Tapping a book must show that book, not a chooser; this
    /// overlay sits full-screen above everything else until content lands.
    private func showLoadingOverlay() {
        isLoadingContent = true
        isDeferringReaderGestures = true
        pageTap.isEnabled = false
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
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
        activeLoadingID = nil
        pendingLoadingCompletionID = nil
        loadingSpinner.stopAnimating()
        loadingContainer.isHidden = true
        // A tap that opened a library cell can finish while this child is
        // being embedded. Always present freshly loaded content with chrome
        // visible; the first intentional reader tap can then enter immersive
        // mode without stealing the book-opening gesture.
        isLoadingContent = false
        synchronizeChromeVisibility()
        onChromeVisibilityRequested?(false)
        onLoadStateChanged?(false)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.activeLoadingID == nil,
                  self.loadingContainer.isHidden else { return }
            self.isDeferringReaderGestures = false
            self.pageTap.isEnabled = true
            self.applyReaderLayoutMode()
            self.recordControlsUsable()
        }
    }

    /// Parsing failed (both the embedded interpreter and, per
    /// `PythonBridge.parseEpub`, its native fallback). Stop the spinner —
    /// an error is a terminal state, never an infinite spinner — and show
    /// the reason under the cover instead of leaving the loading screen.
    private func showLoadingError(_ message: String) {
        cancelActiveBookOpenJourney()
        activeLoadingID = nil
        pendingLoadingCompletionID = nil
        loadingSpinner.stopAnimating()
        loadingStatusLabel.text = message
        loadingRetryButton.isHidden = false
        isLoadingContent = false
        onLoadStateChanged?(false)
    }

    private var uiTestLoadingDelay: TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestLoadingDelayMilliseconds"),
              arguments.indices.contains(arguments.index(after: index)),
              let milliseconds = Double(arguments[arguments.index(after: index)]) else {
            return 0
        }
        return min(max(milliseconds, 0), 10_000) / 1_000
    }

    private func loadUITestFixture(after delay: TimeInterval) {
        let loadingID = activeLoadingID
        let displayFixture = { [weak self] in
            guard let self,
                  let loadingID,
                  self.isCurrentLoad(loadingID, bookID: self.book.id) else { return }
            self.showUITestFixture()
            self.finishLoadingAfterStableTextLayout(loadingID)
        }
        guard delay > 0 else {
            displayFixture()
            return
        }
        loadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self,
                  let loadingID,
                  self.isCurrentLoad(loadingID, bookID: self.book.id) else { return }
            self.showUITestFixture()
            self.finishLoadingAfterStableTextLayout(loadingID)
        }
    }

    private static func documentKind(for book: BookEntity) -> LatencyObservation.DocumentKind {
        book.fileType == .pdf ? .selectableTextPDF : .epub
    }

    private func recordFirstPDFPage(wasNormalized: Bool) {
        guard let journeyID = pendingPDFPageJourneyID,
              journeyID == activeBookOpenJourneyID
        else {
            return
        }
        if wasNormalized {
            LatencyObservationStore.shared.classifyDocument(.normalizedScannedPDF, for: journeyID)
        }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        _ = LatencyObservationStore.shared.record(.firstPDFPage, for: journeyID)
        firstPDFPageReadyJourneyID = journeyID
        finishPDFJourneyIfReady(journeyID)
    }

    private func recordControlsUsable() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.record(.controlsUsable, for: journeyID)
        if pendingPDFPageJourneyID == journeyID {
            controlsReadyJourneyID = journeyID
            finishPDFJourneyIfReady(journeyID)
        } else {
            LatencyObservationStore.shared.finish(journeyID)
            activeBookOpenJourneyID = nil
        }
    }

    private func finishPDFJourneyIfReady(_ journeyID: UUID) {
        guard firstPDFPageReadyJourneyID == journeyID,
              controlsReadyJourneyID == journeyID
        else {
            return
        }
        LatencyObservationStore.shared.finish(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

    private func cancelActiveBookOpenJourney() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.cancel(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

    private func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        activeLoadingID == loadingID && book.id == bookID
    }

    private func finishLoadingAfterStableTextLayout(_ loadingID: UUID) {
        guard isCurrentLoad(loadingID, bookID: book.id) else { return }
        pendingLoadingCompletionID = loadingID
        requestTextLayoutRefresh()
    }

    private func completeLoadingAfterStableTextLayoutIfNeeded() {
        guard let loadingID = pendingLoadingCompletionID,
              isCurrentLoad(loadingID, bookID: book.id),
              scrollView.bounds.width > 1,
              scrollView.bounds.height > 1,
              textView.attributedText.length > 0 || !comicPageImageView.isHidden else {
            return
        }
        pendingLoadingCompletionID = nil
        restoreReadingProgressIfNeeded()
        if let journeyID = activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        }
        hideLoadingOverlay()
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
        rememberedViewportOffsets.removeAll()
        paginatedLayoutResult = nil
        textViewport.resetForChapter()
        // The fallback belongs to a single measured chapter and viewport.
        // A new chapter must always be allowed to attempt canonical paging.
        forcesScrollingForOversizedFragment = false
        let textSettings = ReaderTextSettings(settings: settings)
        lastInlineImageViewportWidth = nil
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        synchronizeChromeVisibility()

        if chapter.isImageOnly {
            contentSurface.mount(.comic)
            paginatedPageOffsets = [0]
            paginatedLayoutResult = nil
            applyReaderLayoutMode()
            if let base64 = chapter.resources?.first?.dataBase64,
               let data = Data(base64Encoded: base64),
               let image = UIImage(data: data) {
                comicPageImageView.image = image
            } else {
                comicPageImageView.image = nil
                showLoadingError(ReaderLoadError.noReadableContent.localizedDescription)
                return
            }
        } else {
            contentSurface.mount(.text)
            applyReaderLayoutMode()
            if let warmChapter = Self.warmRenderedChapters.object(forKey: book.id as NSString),
               warmChapter.chapterIndex == index,
               warmChapter.settings == textSettings {
                textView.attributedText = NSAttributedString(attributedString: warmChapter.attributedText)
            } else if let html = chapter.html,
               let rendered = EpubHtmlRenderer.render(
                   html: html,
                   css: chapter.css,
                   settings: settings,
                   fontDirectoryURL: registeredFontURLs.first?.deletingLastPathComponent(),
                   resources: chapter.resources
               ), !rendered.characters.isEmpty {
                let visible = NSMutableAttributedString(rendered)
                if visible.length > 0 {
                    visible.addAttribute(
                        .foregroundColor,
                        value: settings.readerTheme.previewColors.foreground,
                        range: NSRange(location: 0, length: visible.length)
                    )
                }
                textView.attributedText = visible
                Self.warmRenderedChapters.setObject(
                    WarmRenderedChapter(
                        chapterIndex: index,
                        settings: textSettings,
                        attributedText: visible
                    ),
                    forKey: book.id as NSString
                )
            } else {
                let fallbackText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? EpubHtmlRenderer.plainText(from: chapter.html ?? "")
                    : chapter.text
                textView.text = fallbackText
                textView.textColor = settings.readerTheme.previewColors.foreground
                let font = settings.readerFontFamily == .sans
                    ? UIFont.systemFont(ofSize: settings.readerPointSize)
                    : settings.readerFontFamily == .mono
                        ? UIFont.monospacedSystemFont(ofSize: settings.readerPointSize, weight: .regular)
                        : (UIFont(name: "NewYork", size: settings.readerPointSize)
                            ?? UIFont(name: "Georgia", size: settings.readerPointSize)
                            ?? UIFont.systemFont(ofSize: settings.readerPointSize))
                textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
                if let attributedText = textView.attributedText {
                    Self.warmRenderedChapters.setObject(
                        WarmRenderedChapter(
                            chapterIndex: index,
                            settings: textSettings,
                            attributedText: attributedText
                        ),
                        forKey: book.id as NSString
                    )
                }
            }
            requestTextLayoutRefresh()
            repaintSavedHighlights(chapterIndex: index)
        }
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
        textViewport.updateIndicator(testPage: isUITestFixture ? uiTestPageNumber : nil)
    }

    private func updatePaginatedTextHeight() -> Bool {
        guard isPaginatedMode else { return false }
        guard let facts = textViewport.presentPaginated(
            preservingRawOffset: isViewportTransitioning ? pendingViewportAnchor?.viewportOffset : nil
        ) else { return false }
        if facts.requiresScrollingFallback {
            forcesScrollingForOversizedFragment = true
            paginatedLayoutResult = nil
            return updateScrollingTextHeight()
        }
        forcesScrollingForOversizedFragment = false
        paginatedLayoutResult = facts.layoutResult
        paginatedPageOffsets = facts.canonicalPageOffsets
        updatePaginationProbe()
        return true
    }


    /// TextKit can only start a page on a line boundary; a variable-height
    /// paragraph can still leave the next line crossing the physical bottom
    /// edge. Cover exactly that incomplete remainder, preserving every glyph
    /// on the next page instead of ever showing a chopped line.
    private func updatePageOverflowGuard() {
        textViewport.updateMasks(
            background: settings.readerTheme.previewColors.background,
            paginated: isPaginatedMode
        )
    }

    private func updateScrollingTextHeight() -> Bool {
        let preservesOversizedFragmentFallback = forcesScrollingForOversizedFragment
        guard let facts = textViewport.presentScrolling() else { return false }
        paginatedPageOffsets = [0]
        paginatedLayoutResult = nil
        forcesScrollingForOversizedFragment = preservesOversizedFragmentFallback || facts.requiresScrollingFallback
        return true
    }

    private func updateTextHeightForCurrentLayout() {
        if isPaginatedMode {
            _ = updatePaginatedTextHeight()
        } else {
            _ = updateScrollingTextHeight()
        }
    }

    private func requestTextLayoutRefresh() {
        needsTextLayoutRefresh = true
        view.setNeedsLayout()
    }

    /// Exposes visual pagination facts only in XCTest builds. UI tests need
    /// real glyph positions rather than the outer UITextView frame: the latter
    /// remains safely placed even when a sibling navigation bar overlaps text.
    private func updatePaginationProbe() {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestPaginationProbe"),
              let window = view.window,
              textView.attributedText.length > 0,
              textView.layoutManager.numberOfGlyphs > 0 else { return }

        let glyphRange = textView.layoutManager.glyphRange(for: textView.textContainer)
        guard glyphRange.length > 0 else { return }
        let layoutResult = paginatedLayoutResult
        let protectedFragments = layoutResult?.protectedFragments ?? []
        var completeFragmentRects: [CGRect] = []
        let clippedLineCount: Int
        if let layoutResult {
            let report = layoutResult.clippingReport(at: scrollView.contentOffset.y)
            let bottomMaskedRange = layoutResult.bottomOverflowMaskRange(at: scrollView.contentOffset.y)
            let topMaskedRange = layoutResult.topOverflowMaskRange(at: scrollView.contentOffset.y)
            clippedLineCount = report.clippedFragments.filter { fragment in
                let bottomMasked = bottomMaskedRange.map {
                    !pageOverflowGuard.isHidden && fragment.contentRect.minY >= $0.lowerBound - 0.5
                } ?? false
                let topMasked = topMaskedRange.map {
                    !pageUnderflowGuard.isHidden && fragment.contentRect.maxY <= $0.upperBound + 0.5
                } ?? false
                return !bottomMasked && !topMasked
            }.count
            completeFragmentRects = report.intersectingFragments
                .filter { !report.clippedFragments.contains($0) }
                .map(\.contentRect)
        } else {
            clippedLineCount = 0
            completeFragmentRects = protectedFragments.map(\.contentRect)
        }
        let inset = textView.textContainerInset
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
        let firstCompleteY = completeFragmentRects.first.map {
            textView.convert(CGPoint(x: $0.minX + inset.left, y: $0.minY), to: window).y
        }
        let lastCompleteY = completeFragmentRects.last.map {
            textView.convert(CGPoint(x: $0.maxX + inset.left, y: $0.maxY), to: window).y
        }
        let safeTop = view.convert(
            CGPoint(x: 0, y: view.safeAreaLayoutGuide.layoutFrame.minY),
            to: window
        ).y
        let safeBottom = view.convert(
            CGPoint(x: 0, y: view.safeAreaLayoutGuide.layoutFrame.maxY),
            to: window
        ).y
        let viewportTop = scrollView.convert(scrollView.bounds.origin, to: window).y
        let viewportBottom = scrollView.convert(
            CGPoint(x: scrollView.bounds.minX, y: scrollView.bounds.maxY),
            to: window
        ).y
        paginationProbeLabel.text = [
            "first=\(textView.layoutManager.characterIndexForGlyph(at: firstGlyph))",
            "last=\(textView.layoutManager.characterIndexForGlyph(at: lastGlyph))",
            "firstY=\(Int(firstPoint.y.rounded()))",
            "lastY=\(Int(lastPoint.y.rounded()))",
            "firstCompleteY=\(Int((firstCompleteY ?? firstPoint.y).rounded()))",
            "lastCompleteY=\(Int((lastCompleteY ?? lastPoint.y).rounded()))",
            "safeTop=\(Int(safeTop.rounded()))",
            "safeBottom=\(Int(safeBottom.rounded()))",
            "viewportTop=\(Int(viewportTop.rounded()))",
            "viewportBottom=\(Int(viewportBottom.rounded()))",
            "offset=\(Int(scrollView.contentOffset.y.rounded()))",
            "page=\(pageNumber(at: scrollView.contentOffset.y))",
            "total=\(paginatedLayoutResult?.canonicalPageOffsets.count ?? paginatedPageOffsets.count)",
            "textFrameHeight=\(Int(textView.bounds.height.rounded()))",
            "measuredTextHeight=\(Int(paginatedTextHeightConstraint.constant.rounded()))",
            "viewportHeight=\(Int(scrollView.bounds.height.rounded()))",
            "clippedLineCount=\(clippedLineCount)",
            "chromeHidden=\(chromeHidden ? 1 : 0)",
            "paginatedHeightActive=\(paginatedTextHeightConstraint.isActive ? 1 : 0)",
            "scrollingHeightActive=\(scrollingTextHeightConstraint.isActive ? 1 : 0)",
        ].joined(separator: ";")
    }

    private func pageNumber(at offset: CGFloat) -> Int {
        textViewport.pageNumber(at: offset)
    }

    private func pageOffset(for page: Int) -> CGFloat {
        textViewport.pageOffset(for: page)
    }

    @objc private func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              loadingContainer.isHidden,
              !isDeferringReaderGestures else { return }
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
        // The host owns the whole constraint transaction (navigation, reader
        // viewport and mini player). A second chrome tap is accepted as a new
        // target state; page turns remain blocked until that host transaction
        // has supplied final geometry.
        textView.accessibilityHint = L10n.string("reader.toggleControls")
        prepareForViewportTransition()
        onChromeVisibilityRequested?(!chromeHidden)
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
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: chapterIndex)
                },
                onRemoveDownload: { chapterIndex in
                    if let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) {
                        Task { try? await LocalAudioArtifactStore.shared.removeDownloadedAudio(
                            bookID: embeddedBookID,
                            chapterIndex: chapterIndex
                        ) }
                    } else {
                        DownloadManager.deleteChapter(jobId: snapshot.jobId, chapterIndex: chapterIndex)
                    }
                },
                onDownloadAll: { [weak self] in
                    guard let self else { return }
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: nil)
                },
                onCancelDownloads: EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) == nil
                    ? { Task { await DownloadManager.shared.cancel(jobId: snapshot.jobId) } }
                    : nil,
                onClearDownloads: {
                    if let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) {
                        Task { try? await LocalAudioArtifactStore.shared.clearDownloadedAudio(bookID: embeddedBookID) }
                    } else {
                        Task { await DownloadManager.shared.clearDownloadedBook(jobId: snapshot.jobId) }
                    }
                },
                onRetryFailed: EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId).map { _ in
                    { [weak self] in
                        guard let self,
                              let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) else {
                            return
                        }
                        Task { @MainActor [weak self] in
                            let failed = (try? await LocalAudioArtifactStore.shared.failedIndices(
                                bookID: embeddedBookID
                            )) ?? []
                            for chapterIndex in failed {
                                self?.requestAudioDownload(snapshot: snapshot, chapterIndex: chapterIndex)
                            }
                        }
                    }
                },
                onExport: EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId).map { bookID in
                    { [weak self] in
                        guard let self else { return }
                        LocalAudiobookShareCoordinator.exportAndPresent(bookID: bookID, from: self)
                    }
                }
            )
            let nav = UINavigationController(rootViewController: controller)
            configureTOCSheetPresentation(nav)
            present(nav, animated: true)
            return
        }
        let sheet = TocSheetController(rows: tocRows, initialChapterIndex: selectedChapter) { [weak self] chapterIndex in
            guard let self else { return }
            self.persistReadingProgress()
            self.selectedChapter = chapterIndex
            self.showChapter(chapterIndex)
            self.scrollView.setContentOffset(.zero, animated: false)
        }
        let nav = UINavigationController(rootViewController: sheet)
        configureTOCSheetPresentation(nav)
        present(nav, animated: true)
    }

    /// Keeps the chapter index as a native large sheet: it reaches the top
    /// safe area while preserving the system grabber and swipe-to-dismiss
    /// gesture rather than imitating either with custom layout.
    private func configureTOCSheetPresentation(_ navigationController: UINavigationController) {
        navigationController.modalPresentationStyle = .pageSheet
        guard let sheet = navigationController.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = true
    }

    private func requestAudioDownload(snapshot: JobSnapshot, chapterIndex: Int?) {
        guard let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) else {
            Task {
                if let chapterIndex {
                    await DownloadManager.shared.enqueueSelected(
                        snapshot: snapshot,
                        epubZeroBasedIndices: [chapterIndex],
                        baseURL: settings.resolvedBaseURL
                    )
                } else {
                    await DownloadManager.shared.enqueueAll(snapshot: snapshot, baseURL: settings.resolvedBaseURL)
                }
            }
            return
        }
        guard embeddedBookID == book.id,
              let url = try? library.openBookFile(id: embeddedBookID) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let requestedIndices = chapterIndex.map { Set([$0]) }
                let promoted = try await LocalAudioArtifactStore.shared.promoteAvailable(
                    bookID: embeddedBookID,
                    chapterIndices: requestedIndices
                )
                if let chapterIndex, promoted.contains(chapterIndex) {
                    let isCompleteDownload = (try? await LocalAudioArtifactStore.shared.hasCompleteDownloadedAudio(
                        bookID: embeddedBookID
                    )) ?? false
                    self.book.cachedOffline = isCompleteDownload
                    self.library.recordConversion(
                        jobId: snapshot.jobId,
                        for: embeddedBookID,
                        cachedOffline: isCompleteDownload
                    )
                    return
                }
                let completed = try await EmbeddedConversionCoordinator.stream(
                    bookURL: url,
                    bookID: embeddedBookID,
                    autoPlay: false,
                    requiresWiFi: !self.settings.allowCellularAudioConversion,
                    priorityChapterIndices: chapterIndex.map { [$0] } ?? [],
                    requestedChapterIndices: chapterIndex.map { [$0] },
                    drivesPlayer: false,
                    player: self.player,
                    onChapterAvailable: { chapter in
                        guard chapterIndex == nil || chapter.index == chapterIndex else { return }
                        Task {
                            try? await LocalAudioArtifactStore.shared.promote(
                                bookID: embeddedBookID,
                                chapterIndex: chapter.index
                            )
                        }
                    }
                )
                for chapter in completed.playableChapters
                    where chapterIndex == nil || chapter.index == chapterIndex {
                    try? await LocalAudioArtifactStore.shared.promote(
                        bookID: embeddedBookID,
                        chapterIndex: chapter.index
                    )
                }
                let isCompleteDownload = (try? await LocalAudioArtifactStore.shared.hasCompleteDownloadedAudio(
                    bookID: embeddedBookID
                )) ?? false
                self.book.lastJobId = completed.jobId
                self.book.cachedOffline = isCompleteDownload
                self.library.recordConversion(
                    jobId: completed.jobId,
                    for: embeddedBookID,
                    cachedOffline: isCompleteDownload
                )
            } catch {
                // The artifact manifest records the per-chapter failure and
                // the TOC renders it on its next appearance.
            }
        }
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
        rememberedViewportOffsets.removeAll()
        // Typography and margins can make a formerly oversized protected
        // fragment fit again. Re-evaluate against the final new viewport.
        forcesScrollingForOversizedFragment = false
        let nextTextSettings = ReaderTextSettings(settings: settings)
        let needsTextRerender = lastRenderedTextSettings != nextTextSettings
        let colors = settings.readerTheme.previewColors
        view.backgroundColor = colors.background
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        pageIndicator.textColor = colors.foreground.withAlphaComponent(0.7)
        pageOverflowGuard.backgroundColor = colors.background
        pageUnderflowGuard.backgroundColor = colors.background
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
        guard canNavigateReader, gesture.state == .ended, isPaginatedMode else { return }
        let translation = gesture.translation(in: scrollView)
        guard abs(translation.x) > 40, abs(translation.x) > abs(translation.y) else { return }
        navigatePage(forward: translation.x < 0)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // UITextView installs its own single-tap recognizers for selectable
        // text. Let the reader's non-link tap reach the immersive action too;
        // long-press selection and link handling keep their native behavior.
        gestureRecognizer === pageTap || otherGestureRecognizer === pageTap
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // A centre tap is the reader's primary action. Waiting for UITextView
        // recognizers makes native EPUB typography swallow that tap before the
        // reader can hide chrome. Links are excluded in `shouldReceive`, and
        // text selection remains available through its long-press gesture.
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pageTap else { return true }
        let point = touch.location(in: textView)
        return !isLink(at: point)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Chrome requests are latest-wins. They must be accepted while a
        // previous viewport transaction is committing, whereas page turns
        // still wait for that final geometry.
        if gestureRecognizer === pageTap {
            return !isDeferringReaderGestures && loadingContainer.isHidden
        }
        guard canNavigateReader else { return false }
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

    private var canNavigateReader: Bool {
        Self.allowsReaderNavigation(
            isDeferringReaderGestures: isDeferringReaderGestures,
            isLoadingOverlayHidden: loadingContainer.isHidden,
            isViewportTransitioning: isViewportTransitioning
        )
    }

    nonisolated static func allowsReaderNavigation(
        isDeferringReaderGestures: Bool,
        isLoadingOverlayHidden: Bool,
        isViewportTransitioning: Bool = false
    ) -> Bool {
        !isDeferringReaderGestures && isLoadingOverlayHidden && !isViewportTransitioning
    }

    private var measuredPageCount: Int {
        max(1, paginatedLayoutResult?.canonicalPageOffsets.count ?? paginatedPageOffsets.count)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isPaginatedMode {
            updatePageIndicator()
            updatePageOverflowGuard()
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
        guard canNavigateReader, gesture.state == .ended, !isPaginatedMode else { return }
        navigateScrollChapter(forward: true)
    }

    @objc private func swipeChapterBackward(_ gesture: UISwipeGestureRecognizer) {
        guard canNavigateReader, gesture.state == .ended, !isPaginatedMode else { return }
        navigateScrollChapter(forward: false)
    }

    @objc private func uiTestPreviousChapter() {
        navigateScrollChapter(forward: false)
    }

    @objc private func uiTestNextChapter() {
        navigateScrollChapter(forward: true)
    }

    private func navigateScrollChapter(forward: Bool) {
        guard canNavigateReader else { return }
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
        guard canNavigateReader else { return }
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
        case .slide:
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
        case .flip:
            performHorizontalPageCurl(to: offset, forward: forward)
        }
    }

    /// A horizontal page fold around the vertical reading edge. UIKit's
    /// built-in curl only travels vertically and `transitionFlip…` rotates
    /// like a card, so neither represents turning a book page.
    private func performHorizontalPageCurl(to offset: CGPoint, forward: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled,
              !ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion"),
              let outgoingPage = scrollView.snapshotView(afterScreenUpdates: false) else {
            scrollView.setContentOffset(offset, animated: false)
            isPageTransitioning = false
            return
        }

        let frame = scrollView.convert(scrollView.bounds, to: view)
        scrollView.setContentOffset(offset, animated: false)
        outgoingPage.frame = frame
        outgoingPage.accessibilityIdentifier = "reader.pageCurl"
        outgoingPage.isAccessibilityElement = true
        outgoingPage.accessibilityLabel = "Page turning"
        outgoingPage.layer.isDoubleSided = false
        outgoingPage.layer.anchorPoint = CGPoint(x: forward ? 1 : 0, y: 0.5)
        outgoingPage.layer.position = CGPoint(x: forward ? frame.maxX : frame.minX, y: frame.midY)

        let foldShadow = CAGradientLayer()
        foldShadow.frame = outgoingPage.bounds
        foldShadow.colors = forward
            ? [UIColor.black.withAlphaComponent(0.30).cgColor, UIColor.clear.cgColor]
            : [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.30).cgColor]
        foldShadow.startPoint = CGPoint(x: forward ? 1 : 0, y: 0.5)
        foldShadow.endPoint = CGPoint(x: forward ? 0 : 1, y: 0.5)
        outgoingPage.layer.addSublayer(foldShadow)
        view.addSubview(outgoingPage)

        var fold = CATransform3DIdentity
        fold.m34 = -1 / 900
        fold = CATransform3DRotate(fold, forward ? -.pi / 2 : .pi / 2, 0, 1, 0)
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            outgoingPage.layer.transform = fold
            outgoingPage.alpha = 0.92
        } completion: { _ in
            outgoingPage.removeFromSuperview()
            self.isPageTransitioning = false
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
        contentSurface.mount(.pdf(url))
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
        // Reader controls use the familiar three vertical zones: a middle
        // column toggles chrome anywhere along the readable page, while the
        // left and right columns turn pages in paginated mode. Depending on
        // y made a tap in the visual middle near the top or bottom turn pages
        // unexpectedly.
        let middleColumn = bounds.insetBy(dx: bounds.width / 3, dy: 0)
        if middleColumn.contains(point) {
            return .toggleChrome
        }
        guard isPaginated else { return .none }
        return .turnPage(forward: point.x >= bounds.midX)
    }
}

enum ReaderLoadingLayoutMetrics {
    static let coverAspectRatio: CGFloat = 1.5
    static let preferredCoverWidthFraction: CGFloat = 0.42
    static let maximumCoverWidthFraction: CGFloat = 0.60
    static let maximumCoverHeightFraction: CGFloat = 0.42
    static let minimumVerticalMargin: CGFloat = 24
    static let preferredTopSpacing: CGFloat = 48
}

struct ReaderViewportConfiguration: Equatable {
    let allowsVerticalScrolling: Bool
    let allowsChapterSwipes: Bool
    let usesPaginatedTextHeight: Bool
    let showsPageIndicator: Bool
    let usesScreenEdges: Bool

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
            showsPageIndicator: paginated && !chromeHidden && showsPageNumbers,
            // Immersive mode removes reader chrome, not the system safe
            // area. Keeping text inside it prevents content from extending
            // under the status bar or home indicator during a reflow.
            usesScreenEdges: false
        )
    }
}

enum ReaderTextViewFactory {
    /// The reader intentionally uses NSLayoutManager for pagination, glyph
    /// positions, and page-boundary calculations. Build it with TextKit 1 so
    /// those accesses do not force UIKit to switch a TextKit 2 view at runtime.
    static func make() -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return UITextView(frame: .zero, textContainer: textContainer)
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
    private let initialChapterIndex: Int
    private let onSelect: (Int) -> Void
    private var hasScrolledToInitialFocus = false

    init(
        rows: [ReaderTocRow],
        initialChapterIndex: Int,
        onSelect: @escaping (Int) -> Void
    ) {
        self.rows = rows
        self.initialChapterIndex = initialChapterIndex
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasScrolledToInitialFocus,
              let rowIndex = rows.firstIndex(where: { $0.chapterIndex == initialChapterIndex }) else {
            return
        }
        hasScrolledToInitialFocus = true
        view.layoutIfNeeded()
        tableView.layoutIfNeeded()
        tableView.scrollToRow(
            at: IndexPath(row: rowIndex, section: 0),
            at: .middle,
            animated: false
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter") ?? UITableViewCell(style: .default, reuseIdentifier: "chapter")
        let row = rows[indexPath.row]
        let isFocused = row.chapterIndex == initialChapterIndex
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.chapterIndex.map { L10n.string("reader.chapter", $0 + 1) }
        content.textProperties.font = .preferredFont(forTextStyle: isFocused ? .headline : .body)
        content.textProperties.color = isFocused ? view.tintColor : .label
        content.secondaryTextProperties.color = isFocused ? view.tintColor : .secondaryLabel
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = isFocused ? view.tintColor.withAlphaComponent(0.12) : .clear
        cell.backgroundConfiguration = background
        cell.indentationLevel = row.level
        cell.accessibilityTraits = isFocused ? [.button, .selected] : .button
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
