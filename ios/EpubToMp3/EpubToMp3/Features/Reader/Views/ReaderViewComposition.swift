#if os(iOS)
import UIKit

/// Owns the reader hierarchy and constraints. The controller supplies private
/// selectors and commits viewport transitions after final host geometry.
@MainActor
final class ReaderViewComposition {
    typealias Target = UIViewController
    struct Actions {
        let readerTap: Selector
        let chapterForward: Selector
        let chapterBackward: Selector
        let toggleChromeAccessibility: Selector
        let horizontalSwipe: Selector
        let resetFlicker: Selector
        let toggleChrome: Selector
        let pageLeft: Selector
        let pageRight: Selector
        let previousChapter: Selector
        let nextChapter: Selector
        let retryLoading: Selector
    }

    let view: UIView
    private unowned let target: Target
    private let actions: Actions
    private let settings: AppSettings
    private let onUpdateFlicker: () -> Void
    private let onPDFPageReady: (Bool) -> Void
    let loading = ReaderLoadingPresentation()
    let textView = ReaderTextViewFactory.make()
    let comicPageImageView = UIImageView()
    lazy var contentSurface = ReaderContentSurface(
        readerView: view,
        scrollView: scrollView,
        textView: textView,
        comicPageImageView: comicPageImageView
    )
    let scrollView = UIScrollView()
    let pageIndicator = UILabel()
    let pageOverflowGuard = UIView()
    let pageUnderflowGuard = UIView()
    let flickerChapterLabel = UILabel()
    let flickerSummaryLabel = UILabel()
    let flickerResetButton = UIButton(type: .system)
    let scrollProbeLabel = UILabel()
    let paginationProbeLabel = UILabel()
    lazy var pageTap = UITapGestureRecognizer(
        target: target,
        action: actions.readerTap
    )
    lazy var forwardChapterSwipe = UISwipeGestureRecognizer(
        target: target,
        action: actions.chapterForward
    )
    lazy var backwardChapterSwipe = UISwipeGestureRecognizer(
        target: target,
        action: actions.chapterBackward
    )
    let testProbeStack = UIStackView()
    var loadingContainer: UIView { loading.loadingContainer }
    var loadingCoverView: UIImageView { loading.loadingCoverView }
    var loadingSpinner: UIActivityIndicatorView { loading.loadingSpinner }
    var loadingStatusLabel: UILabel { loading.loadingStatusLabel }
    var loadingRetryButton: UIButton { loading.loadingRetryButton }
    var paginatedTextHeightConstraint: NSLayoutConstraint!
    var scrollingTextHeightConstraint: NSLayoutConstraint!
    var scrollTopToSafeArea: NSLayoutConstraint!
    var scrollTopToRoot: NSLayoutConstraint!
    var scrollBottomToPageIndicator: NSLayoutConstraint!
    var scrollBottomToSafeArea: NSLayoutConstraint!
    var scrollBottomToRoot: NSLayoutConstraint!
    lazy var textViewport = ReaderTextViewport(
        textView: textView,
        scrollView: scrollView,
        hostView: view,
        pageIndicator: pageIndicator,
        overflowGuard: pageOverflowGuard,
        underflowGuard: pageUnderflowGuard,
        paginatedHeight: paginatedTextHeightConstraint,
        scrollingHeight: scrollingTextHeightConstraint
    )

    init(view: UIView, target: Target, actions: Actions, settings: AppSettings,
         onUpdateFlicker: @escaping () -> Void, onPDFPageReady: @escaping (Bool) -> Void) {
        self.view = view
        self.target = target
        self.actions = actions
        self.settings = settings
        self.onUpdateFlicker = onUpdateFlicker
        self.onPDFPageReady = onPDFPageReady
    }

    func configure(isPaginatedMode: Bool, textDelegate: UITextViewDelegate,
                   scrollDelegate: UIScrollViewDelegate, gestureDelegate: UIGestureRecognizerDelegate) {
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
        textView.delegate = textDelegate
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: settings.readerPointSize))
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityIdentifier = "reader.content"
        textView.isAccessibilityElement = true
        textView.accessibilityLabel = L10n.string("reader.contents")
        textView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.string("reader.toggleControls"),
                                        target: target,
                                        selector: actions.toggleChromeAccessibility)
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
        scrollView.delegate = scrollDelegate
        pageTap.delegate = gestureDelegate
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
        let horizontalSwipe = UIPanGestureRecognizer(target: target, action: actions.horizontalSwipe)
        horizontalSwipe.delegate = gestureDelegate
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
            flickerResetButton.addTarget(target, action: actions.resetFlicker, for: .touchUpInside)
            testProbeStack.addArrangedSubview(flickerChapterLabel)
            testProbeStack.addArrangedSubview(flickerSummaryLabel)
            testProbeStack.addArrangedSubview(flickerResetButton)
            onUpdateFlicker()
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
        pageOverflowGuard.backgroundColor = settings.readerColors.background
        pageOverflowGuard.isHidden = true
        view.addSubview(pageOverflowGuard)
        pageUnderflowGuard.isUserInteractionEnabled = false
        pageUnderflowGuard.accessibilityElementsHidden = true
        pageUnderflowGuard.backgroundColor = settings.readerColors.background
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
            chromeToggle.addTarget(target, action: actions.toggleChrome, for: .touchUpInside)
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
            leftTurn.addTarget(target, action: actions.pageLeft, for: .touchUpInside)
            rightTurn.addTarget(target, action: actions.pageRight, for: .touchUpInside)
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
                ("reader.pageTurn.left", actions.pageLeft, false),
                ("reader.pageTurn.right", actions.pageRight, true),
            ] as [(String, Selector, Bool)] {
                let button = UIButton(type: .custom)
                button.accessibilityIdentifier = identifier
                button.addTarget(target, action: action, for: .touchUpInside)
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
                    ("reader.scrollChapter.previous", actions.previousChapter, false),
                    ("reader.scrollChapter.next", actions.nextChapter, true),
                ] as [(String, Selector, Bool)] {
                    let button = UIButton(type: .custom)
                    button.accessibilityIdentifier = identifier
                    button.addTarget(target, action: action, for: .touchUpInside)
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

        loading.configure(target: target, retryAction: actions.retryLoading, in: view)

        contentSurface.install()
        contentSurface.onPDFPageReady = { [weak self] wasNormalized in
            self?.onPDFPageReady(wasNormalized)
        }
        paginatedTextHeightConstraint = contentSurface.paginatedTextHeightConstraint
        scrollingTextHeightConstraint = contentSurface.scrollingTextHeightConstraint
    }

    static func makeNavigationItem(
        target: AnyObject,
        symbol: String,
        identifier: String,
        label: String,
        action: Selector
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: symbol),
            style: .plain,
            target: target,
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

}
#endif
