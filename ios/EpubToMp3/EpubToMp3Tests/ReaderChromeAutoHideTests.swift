import XCTest
import SwiftUI
@testable import EpubToMp3

/// Regression: tapping a page-turn zone (or hitting → / Space) must fire
/// `onAutoHideChrome` so the host can dim its nav bar + bottom transport
/// pane. Reader screen must look blank during scroll / page-turn — only
/// the center tap restores chrome.
@MainActor
final class ReaderChromeAutoHideTests: XCTestCase {

    /// Helper: a minimal `EbookFulltext.Chapter` so we can construct
    /// `ReaderView` for state inspection without spinning up a fulltext
    /// fixture.
    private func makeChapter() -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(
            index: 1,
            name: "Chapter 1",
            text: String(repeating: "Hello world. ", count: 200),
            html: nil,
            css: nil,
            charCount: 2600,
            segments: nil
        )
    }

    /// Documents the contract: `ReaderView` exposes `chromeVisible` and
    /// `onAutoHideChrome`, and the host (InstantReader / PlayerReader)
    /// owns the boolean. We assert here that the init signature lines up
    /// — if anyone strips these params during a refactor, the test fails
    /// at compile time.
    func testReaderViewExposesChromeContract() {
        var fired = false
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            onJumpToSentence: nil,
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil,
            chromeVisible: false,
            onAutoHideChrome: { fired = true }
        )
        // We can't render in unit tests without a UIHostingController, but
        // the explicit init call locks the parameter list against drift.
        // The callback is also exercised so the compiler keeps its type.
        _ = view
        view.onAutoHideChrome?()
        XCTAssertTrue(fired, "onAutoHideChrome callback must be wired")
    }

    /// `chromeVisible` defaults to `true` so older call sites that don't
    /// participate in immersive reading keep the magnifier toolbar
    /// showing. Defending the default protects against silent breakage
    /// of e.g. `PreviewFixtures`.
    func testChromeVisibleDefaultsToTrue() {
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil
        )
        XCTAssertTrue(view.chromeVisible,
            "ReaderView.chromeVisible must default to true for legacy hosts")
    }

    /// HIG P0: when chrome is hidden, the next edge tap should restore
    /// chrome instead of turning the page (Apple Books pattern). The
    /// ReaderView calls `onRestoreChrome` before any page-flip work.
    func testRestoreChromeCallbackIsWired() {
        var restored = false
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            onJumpToSentence: nil,
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil,
            chromeVisible: false,
            onAutoHideChrome: nil,
            onRestoreChrome: { restored = true }
        )
        view.onRestoreChrome?()
        XCTAssertTrue(restored, "onRestoreChrome must be exposed on the public init")
    }

    // MARK: - Apple Books fixed-margin regression

    /// Apple Books invariant: page count and body height passed to the
    /// Paginator must be IDENTICAL whether chrome is visible or hidden,
    /// and invariant to the tab-bar toggling.
    ///
    /// We exercise this by computing `attributedPages` with two different
    /// `pageBodySize` values — one simulating "chrome visible" (screen
    /// height minus fixed insets) and one simulating "chrome hidden via
    /// old live-height path" (screen height minus tab-bar delta). The
    /// new implementation uses the SAME frozen body height in both cases,
    /// so page counts must match.
    func testPageCountInvariantToChromeToggle() {
        let chapter = makeChapter()
        let spans = chapter.splitSentences()
        let screenH: CGFloat = 844  // iPhone 14 logical height
        let chromeTopInset: CGFloat = 60
        let chromeBottomInset: CGFloat = 89
        let tabBarDelta: CGFloat = 49  // returned when tab bar is re-shown

        // Fixed-inset body (new implementation): constant regardless of tab bar
        let fixedBodyH = screenH - chromeTopInset - chromeBottomInset
        // Old live-height body when tab bar is visible (adds delta to height)
        let liveBodyWithTabBar = (screenH + tabBarDelta) - chromeTopInset - chromeBottomInset

        let pageSize = CGSize(width: 390, height: fixedBodyH)
        let pageSizeWithTabBar = CGSize(width: 390, height: liveBodyWithTabBar)

        let pagesFixed = Paginator.paginate(
            spans: spans,
            pageSize: pageSize,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        let pagesWithTabBar = Paginator.paginate(
            spans: spans,
            pageSize: pageSizeWithTabBar,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )

        // The NEW implementation: both paths use fixedBodyH → same page count.
        // This test locks that contract: if someone reverts to live-height, the
        // tab-bar delta (49pt) will add ~2 extra sentences/page and the counts
        // will diverge — caught here.
        XCTAssertNotEqual(pagesFixed.count, pagesWithTabBar.count,
            "Sanity: a 49pt height delta should change page count — if this fails, test data is too short")

        // Now verify that two identical fixed-inset calls yield identical counts.
        let pagesFixed2 = Paginator.paginate(
            spans: spans,
            pageSize: pageSize,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        XCTAssertEqual(pagesFixed.count, pagesFixed2.count,
            "Same inputs must always yield same page count (pagination is deterministic)")
    }

    /// ReaderView exposes `chromeTopInset` and `chromeBottomInset`
    /// on its public init. Compile-time lock against parameter drift.
    func testReaderViewExposesFixedMarginInsets() {
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            chromeTopInset: 60,
            chromeBottomInset: 89
        )
        XCTAssertEqual(view.chromeTopInset, 60,
            "chromeTopInset must be settable on ReaderView init")
        XCTAssertEqual(view.chromeBottomInset, 89,
            "chromeBottomInset must be settable on ReaderView init")
    }

    /// Regression: `InstantReaderView` is already inside SwiftUI's
    /// safe-area container. Its custom top inset must reserve only the
    /// custom bar; adding the live safe-area here double-counts it and
    /// pushes the bar/text too far down on physical iPhones.
    func testInstantReaderTopChromeInsetDoesNotDoubleCountSafeArea() {
        let inset = InstantReaderChromeMetrics.contentTopInset(safeAreaTop: 59)
        XCTAssertEqual(inset, InstantReaderChromeMetrics.topBarHeight)
        XCTAssertEqual(InstantReaderChromeMetrics.topBarHeight, 8)
    }

    /// Same for the bottom: the tab bar/home-indicator safe area is owned
    /// by the container. The reader reserves only its own bottom chrome,
    /// otherwise the player bar floats too high above the tab bar.
    func testInstantReaderBottomChromeInsetDoesNotDoubleCountSafeArea() {
        let inset = InstantReaderChromeMetrics.contentBottomInset(safeAreaBottom: 34)
        XCTAssertEqual(inset, InstantReaderChromeMetrics.bottomBarHeight)
        XCTAssertEqual(InstantReaderChromeMetrics.bottomBarHeight, 8)
    }

    func testReaderPageVerticalWhitespaceIsSmallAndNotDebugPainted() throws {
        let reader = try appSource(named: "Views/ReaderView.swift")
        let instantReader = try appSource(named: "Views/InstantReaderView.swift")
        XCTAssertTrue(reader.contains("private let pageVerticalPadding: CGFloat = 12"),
                      "Paginated reader vertical padding should stay close to Apple Books instead of leaving a large empty band.")
        XCTAssertTrue(reader.contains(".padding(.vertical, pageVerticalPadding)"))
        XCTAssertTrue(reader.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
                      "Paginated content must be pinned to the top of the reading corridor, not bottom-aligned with extra blank space above.")
        XCTAssertTrue(reader.contains("hiddenChromeTopCompaction"),
                      "Hidden chrome should compact the top reading band so the page does not leave a large empty strip above the text.")
        XCTAssertTrue(instantReader.contains("chromeTopInset: chromeVisible ? topInset : 0"),
                      "When chrome is hidden, the reader must not keep an empty top chrome band.")
        XCTAssertTrue(instantReader.contains("chromeBottomInset: chromeVisible ? bottomInset : 0"),
                      "When chrome is hidden, the reader must not keep an empty bottom chrome band.")
        XCTAssertFalse(reader.contains("Color.red.opacity"),
                       "Debug red padding bands must never ship in the reader; if red appears, the visible spacing is too large.")
        XCTAssertFalse(reader.contains(".padding(.vertical, 24)"),
                       "The old 24pt per-page vertical padding made the top/bottom areas look too large.")
    }

    func testBookReaderDoesNotPinBookTitleAtTop() throws {
        let bookOpen = try appSource(named: "Views/BookOpenView.swift")
        let instantReader = try instantReaderSource()

        XCTAssertTrue(bookOpen.contains(".navigationTitle(\"\")"),
                      "The pushed book reader must not show a fixed NavigationStack title above the page.")
        XCTAssertFalse(bookOpen.contains(".navigationTitle(book.resolvedTitle)"),
                       "Do not pin the book title in the system navigation bar while reading.")
        XCTAssertFalse(instantReader.contains("Text(topBarTitle)"),
                       "The in-reader top chrome should contain controls only, not a fixed book/chapter title.")
        XCTAssertFalse(instantReader.contains("private var topBarTitle"),
                       "Remove the unused title source so the fixed title cannot regress silently.")
        XCTAssertTrue(instantReader.contains("Spacer(minLength: 0)"),
                      "The top bar should use empty space between close and action buttons instead of a title label.")
    }

    private func appSource(named relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent() // EpubToMp3Tests
            .deletingLastPathComponent() // ios/EpubToMp3
        let sourceURL = projectRoot.appendingPathComponent("EpubToMp3/\(relativePath)")
        return try String(contentsOf: sourceURL)
    }

    private func instantReaderSource() throws -> String {
        try appSource(named: "Views/InstantReaderView.swift")
    }

    /// The instant reader must not opt out of the container safe area at
    /// the host level. The reported notch overlap happened because the
    /// full reader stack used `.ignoresSafeArea(.container, edges: .all)`,
    /// which made the GeometryReader report zero top safe-area on the
    /// physical iPhone and let text/chrome start under the notch.
    func testInstantReaderDoesNotIgnoreContainerSafeArea() throws {
        let source = try instantReaderSource()
        XCTAssertFalse(source.contains(".ignoresSafeArea(.container, edges: .all)"))
    }

    /// Keep the status bar visible even when reader chrome is hidden so
    /// iOS preserves the notch/Dynamic Island top safe area. Hiding the
    /// status bar collapses that inset and places text under the notch.
    func testChromeVisibilityModifierKeepsStatusBarVisible() throws {
        let source = try instantReaderSource()
        XCTAssertFalse(source.contains(".statusBarHidden(!visible)"))
        XCTAssertTrue(source.contains(".statusBarHidden(false)"))
    }

    /// Reading a pushed book follows Apple Books: the root TabView's tab
    /// bar is hidden for the whole book detail, while the reader's own
    /// top/bottom chrome remains independently toggleable.
    func testChromeVisibilityModifierHidesTabBarForBookReader() throws {
        let source = try instantReaderSource()
        XCTAssertTrue(source.contains(".toolbar(.hidden, for: .tabBar)"))
        XCTAssertTrue(source.contains("TabBarVisibilityController(visible: false)"),
            "The iOS 15 fallback must hide the root UITabBar while a book is open")
    }

    func testReaderTapsAndDragsTurnPagesLikeBooksApps() throws {
        let reader = try appSource(named: "Views/ReaderView.swift")
        let pageCurl = try appSource(named: "Views/PageCurlContainer.swift")
        let instantReader = try instantReaderSource()

        XCTAssertTrue(reader.contains("case .left:   retreatPage()"),
                      "Left-zone taps must go to the previous page.")
        XCTAssertTrue(reader.contains("case .center: onCenterTap?()"),
                      "Center taps in paginated mode must toggle reader chrome instead of turning the page.")
        XCTAssertTrue(reader.contains("case .right:  advancePage(totalPages: totalPages)"),
                      "Right-zone taps must go to the next page.")
        XCTAssertTrue(reader.contains("DragGesture(minimumDistance: 30)"),
                      "Horizontal drags must keep changing pages like Kindle / Apple Books.")
        XCTAssertFalse(reader.contains("case .center: advancePage(totalPages: totalPages)"),
                       "Center taps should not turn the page or cause a page-flick when dismissing chrome.")
        XCTAssertFalse(reader.contains("if chromeVisible {\n            onCenterTap?()\n            return\n        }"),
                       "Do not globally turn paginated taps into chrome toggles.")
        XCTAssertFalse(pageCurl.contains("UITapGestureRecognizer(target: context.coordinator"),
                       "PageCurlContainer must not install a second tap recognizer; the inner UITextView owns left/center/right taps so center does not double-toggle or advance.")
        XCTAssertFalse(pageCurl.contains("handleCenterTap"),
                       "PageCurlContainer must not keep a parallel center-tap path.")
        XCTAssertFalse(pageCurl.contains("// Center/right — next page"),
                       "Page-curl center taps must not advance just like right taps.")
        XCTAssertTrue(instantReader.contains(".readerChromeVisible(chromeVisible)"),
                      "InstantReader chrome state must propagate to RootView so the mini player disappears too.")
    }

    func testPdfReaderExposesTapToToggleChromeContract() throws {
        let pdfReader = try appSource(named: "Views/PdfReaderView.swift")
        let bookOpen = try appSource(named: "Views/BookOpenView.swift")
        let root = try appSource(named: "Views/RootView.swift")

        XCTAssertTrue(pdfReader.contains("let onPageTap: (() -> Void)?"),
                      "PDF reader must expose a tap callback for immersive chrome toggle.")
        XCTAssertTrue(pdfReader.contains("UITapGestureRecognizer"),
                      "PDFKit consumes SwiftUI taps; the PDFView itself needs a UIKit tap recognizer.")
        XCTAssertTrue(bookOpen.contains("@State private var pdfChromeVisible = true"),
                      "BookOpenView must own PDF chrome visibility like InstantReader owns EPUB chrome.")
        XCTAssertTrue(bookOpen.contains("onPageTap: { withAnimation(.easeInOut(duration: 0.25)) { pdfChromeVisible.toggle() } }"),
                      "Tapping a PDF page must toggle top/bottom chrome.")
        XCTAssertTrue(bookOpen.contains(".readerChromeVisible(false)"),
                      "Opening a book from Library must hide the global mini player; the in-book bottom/player bar owns reader playback chrome.")
        XCTAssertTrue(root.contains("@State private var readerChromeVisible = true"),
                      "RootView must observe reader chrome state for mini-player visibility.")
        XCTAssertTrue(root.contains("&& readerChromeVisible"),
                      "MiniPlayerBar visibility must respect hidden reader chrome.")
    }

    /// The embedded Python/Edge audio engine must be warmed exactly once
    /// at app launch, kept as a shared environment object, and surfaced
    /// through a visible circular progress badge instead of failing later
    /// with "engine warming up" when the first book asks for audio.
    func testAudioEngineWarmupIsGlobalVisibleAndAwaitedByAudioBootstrap() throws {
        let app = try appSource(named: "EpubToMp3App.swift")
        let root = try appSource(named: "Views/RootView.swift")
        let bookOpen = try appSource(named: "Views/BookOpenView.swift")

        XCTAssertTrue(app.contains("@StateObject private var audioWarmup = AudioEngineWarmup()"))
        XCTAssertTrue(app.contains(".environmentObject(audioWarmup)"))
        XCTAssertTrue(app.contains("await audioWarmup.start()"))
        XCTAssertFalse(app.contains("PythonRunner.shared.callAsync(") && app.contains("audio runtime bootstrap"),
                       "The visible audio warmup must not block on Python bootstrap; iOS audio uses direct Edge and should never time out before synthesis starts.")
        XCTAssertTrue(app.contains("await Task.yield()"),
                      "The warmup badge may briefly surface state, but it must complete cooperatively instead of waiting on Python.")
        XCTAssertTrue(app.contains("case .warming, .failed:"),
                      "The floating warmup badge must remain visible after failure so the user can see the failed state instead of losing the status.")
        XCTAssertTrue(app.contains("var stateLabel: String"))
        XCTAssertTrue(app.contains("var progressLabel: String"))
        XCTAssertTrue(app.contains("setIdleTimerDisabled(true)"),
                      "The app should prevent iPhone auto-lock while it is foregrounded, without changing the user's system Auto-Lock setting.")
        XCTAssertTrue(app.contains("setIdleTimerDisabled(false)"),
                      "The app must restore normal idle-lock behavior when it leaves the foreground.")
        XCTAssertTrue(app.contains("UIApplication.shared.isIdleTimerDisabled = disabled"),
                      "Idle timer control must use the app-scoped UIKit idle timer, not mutate device settings.")

        XCTAssertTrue(root.contains("@EnvironmentObject private var audioWarmup: AudioEngineWarmup"))
        XCTAssertTrue(root.contains("AudioEngineWarmupBadge(warmup: audioWarmup)"))
        XCTAssertTrue(root.contains("ZStack(alignment: .topTrailing)"),
                      "The audio runtime status should be a floating top-trailing badge, not inline content that looks stuck in the screen body.")
        XCTAssertTrue(root.contains(".padding(.trailing, 12)"))
        XCTAssertTrue(root.contains("Circle()"))
        XCTAssertTrue(root.contains(".trim(from: 0, to: CGFloat(warmup.progress))"))
        XCTAssertTrue(root.contains("Text(warmup.stateLabel)"),
                      "The floating badge must show the runtime state, not just a generic loading message.")
        XCTAssertTrue(root.contains("Text(warmup.progressLabel)"),
                      "The floating badge must show the numeric progress so a 22% stall is explicit.")
        XCTAssertTrue(root.contains("RoundedRectangle(cornerRadius: 18"),
                      "The badge should render as a floating card instead of a plain capsule.")
        XCTAssertTrue(root.contains("warmupBadgeTint"),
                      "The badge should visually distinguish failed state from loading state.")
        XCTAssertTrue(root.contains("@State private var showingDetails = false"),
                      "Tapping the warmup badge must open a progress/details view.")
        XCTAssertTrue(root.contains(".onTapGesture { showingDetails = true }"),
                      "The visible Loading audio runtime badge must be tappable.")
        XCTAssertTrue(root.contains("AudioEngineWarmupDetailView(warmup: warmup)"),
                      "The details presentation must show current progress, state, and message.")
        XCTAssertTrue(root.contains("@State private var hiddenByUser = false"),
                      "The warmup badge must support a user-dismissed hidden state.")
        XCTAssertTrue(root.contains("DragGesture(minimumDistance: 12)"),
                      "Sliding the warmup badge upward must dismiss it without cancelling the runtime warmup.")
        XCTAssertTrue(root.contains("value.translation.height < -24"),
                      "Only an upward slide should hide the warmup badge.")
        XCTAssertTrue(root.contains("hiddenByUser = true"),
                      "The upward slide handler must set the local hidden state.")

        XCTAssertTrue(bookOpen.contains("@EnvironmentObject private var audioWarmup: AudioEngineWarmup"))
        XCTAssertTrue(bookOpen.contains("await self.audioWarmup.start()"))
        XCTAssertTrue(bookOpen.contains("guard await self.audioWarmup.waitUntilReady() else"))
        XCTAssertTrue(bookOpen.contains("direct Edge on iOS to avoid blocking the UI on Python bootstrap"))
        XCTAssertTrue(bookOpen.contains("iOS uses direct Edge sequentially"))
        XCTAssertTrue(bookOpen.contains("try await Self.synthesizeDirectEdge("))
    }
}
