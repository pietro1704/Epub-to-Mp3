import SwiftUI

/// Personalisable EPUB reader. Supports two layout modes:
///
/// - **Scrolling** — `ScrollView` + `LazyVStack` of sentence rows. The
///   active sentence (driven by `SyncEngine`) gets a yellow background;
///   the scroll view auto-scrolls to centre it unless the user is
///   actively dragging.
/// - **Paginated** — chapter text is split into pages that fit the
///   current font/size/line-spacing/column-width. The reader shows one
///   page at a time and the user turns pages by tap (left/right zone),
///   click, scroll wheel, swipe, or keyboard (←/→/Space/PageUp/PageDown/J/K).
///
/// All visual choices come from `AppSettings`: theme, custom colour,
/// font family, font size, line spacing, horizontal margin, column
/// width.
struct ReaderView: View {
    let chapter: EbookFulltext.Chapter
    let spans: [SentenceSpan]
    let currentSentenceId: String?
    let onJumpToSentence: ((SentenceSpan) -> Void)?
    /// Called when the user advances past the last page of the current
    /// chapter. The caller is expected to swap `chapter`/`spans` for the
    /// next chapter; the reader resets `currentPage` to 0 via the
    /// `onChange(of: chapter.id)` modifier. Returns `true` if the
    /// caller handled the advance (= there *is* a next chapter); `false`
    /// keeps the user on the last page of the current chapter.
    let onAdvanceChapter: (() -> Bool)?
    /// Called when the user goes back from page 0. Same contract as
    /// `onAdvanceChapter`; returning `true` should land them on the
    /// *last* page of the previous chapter — but we don't currently
    /// track previous-chapter page count from here, so the caller is
    /// responsible for any page positioning after the chapter swap.
    let onPreviousChapter: (() -> Bool)?
    var onCenterTap: (() -> Void)?
    /// Drives the visibility of the reader's own inline toolbar (the
    /// magnifying-glass row sitting just below the nav bar). Default is
    /// `true` so legacy call sites that don't manage immersive chrome keep
    /// the toolbar showing.
    var chromeVisible: Bool = true
    /// Fixed vertical space reserved for the host's top chrome (nav bar,
    /// custom top bar). Pagination uses a body height that already excludes
    /// this amount, so the host's chrome — rendered as an overlay — sits
    /// above the margin without covering any text. Hosts may pass 0 while
    /// chrome is hidden so the page can reclaim that space.
    /// Default 0 for legacy call sites that don't participate in this protocol.
    var chromeTopInset: CGFloat = 0
    /// Fixed vertical space reserved for the host's bottom chrome (player
    /// bar, mini player, page footer). Same contract as `chromeTopInset`.
    var chromeBottomInset: CGFloat = 0
    /// When true, paginate against a FROZEN `stableBodyHeight` (seeded
    /// on first appear) instead of the live `geo.size.height`. Combined
    /// with `chromeTopInset == 0 && chromeBottomInset == 0` this gives
    /// the "chrome is a true overlay" pattern the user asked for: text
    /// is laid out edge-to-edge once and stays put forever. Chrome bars
    /// — opaque OR translucent — cover the text wherever they appear
    /// without nudging the layout. No reflow on chrome toggle, on
    /// status-bar toggle, or on any safe-area animation. Default
    /// `false` so legacy callers (PlayerReaderView) keep the
    /// `geo.size.height - 76` live-height path they were using.
    var useStableBodyHeight: Bool = false
    /// Fired the first time the user advances/retreats a page so the
    /// host can dim its own chrome (nav bar, mini player). The host is
    /// responsible for the actual `withAnimation`. The callback fires on
    /// every page turn — the host should no-op if chrome is already
    /// hidden.
    var onAutoHideChrome: (() -> Void)? = nil
    /// Apple Books pattern: when chrome is hidden, a tap on the left/right
    /// edge zones first restores chrome instead of turning the page.
    /// Discovery is otherwise too narrow — only the center 33% knows to
    /// toggle. The host owns this restore (animates `chromeVisible = true`).
    var onRestoreChrome: (() -> Void)? = nil
    /// Tap-on-link handler. Receives the URL from the EPUB's `<a href>`.
    /// Return `true` if handled (internal chapter jump, anchor scroll);
    /// `false` to let iOS open the URL externally (Safari / mail).
    var onLinkTap: ((URL) -> Bool)? = nil
    /// Asked when the user taps the floating "Follow audio" pill that
    /// surfaces after the reader strays from the audio position. The
    /// host should swap `chapter`/`spans` to the audio's current chapter
    /// (and ideally also seek to the sentence underway). Sentence-level
    /// re-sync is handled internally once `currentSentenceId` lands on a
    /// span that lives in the newly-loaded chapter.
    var onJumpToPlayerPosition: (() -> Void)? = nil
    /// Optional display label of the chapter the audio is currently
    /// narrating. When non-nil AND different from the reader's chapter,
    /// the floating pill widens to surface "Tocando: <title>" so the
    /// user knows where the audio went. Nil ⇒ generic "Acompanhar
    /// áudio" label (audio is paused, or no divergence to disclose).
    var playerChapterLabel: String? = nil
    /// When non-nil AND the layout is `.scrolling`, the reader renders the
    /// ENTIRE book as one continuous scroll (every chapter stacked in a
    /// single `ScrollView`/`LazyVStack`) instead of just the current
    /// `chapter`. The host (InstantReaderView) passes `fulltext.chapters`;
    /// hosts that only hold the current chapter (PlayerReaderView) leave
    /// this nil and keep the per-chapter behaviour. Tapping a chapter in
    /// the array scrolls to it; `onJumpToChapterIndex` lets the host mirror
    /// the active chapter into its own state for TOC / persistence.
    var bookChapters: [EbookFulltext.Chapter]? = nil
    /// Called when continuous scroll brings a new chapter into view, so the
    /// host can mirror `currentChapterIndex` (TOC highlight, position
    /// persistence). Zero-based EPUB chapter index.
    var onScrolledToChapter: ((Int) -> Void)? = nil
    /// Fires once, after a `startAtLastPage` retreat has actually seeded
    /// `currentPage` to the real last-page index (Int.max normalised) — or
    /// immediately, synchronously, if this instance never needed the
    /// last-page seed. The host uses this (not the audio player's own
    /// chapter-index catching up) to know when it's SAFE to clear its own
    /// "start at last page" flag. Reacting to the audio index instead races
    /// ahead of pagination: audio starts near-instantly, but the retreat's
    /// `Int.max` seed can still be live when the host's flag flips back to
    /// `false` and re-renders this SAME `.id()`-stable identity with
    /// `startAtLastPage: false` — which was observed on-device to reset
    /// `currentPage` back to 0 mid-flight (the "retreat lands on page 1"
    /// bug), even though `.id()` is unchanged. Decoupling the reset from
    /// audio timing removes that race entirely.
    var onLastPageLanded: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    @Environment(\.epubFontDirectory) private var epubFontDirectory
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast
    @State private var currentPage: Int = 0
    /// The chapter.id that was current when currentPage was last set.
    /// Used to suppress the footer when a new chapter arrives but onChange
    /// hasn't yet reset currentPage — preventing the "77/6" flash caused
    /// by body() receiving new chapter before onChange fires.
    @State private var currentPageChapterId: String = ""
    /// Continuous-scroll mode: the chapter index the scroll itself last
    /// reported (via `onScrolledToChapter`). When `chapter.id` changes
    /// because the host mirrored that very scroll back into
    /// `currentChapterIndex`, we must NOT re-issue a `scrollTo` — that
    /// would fight the user's own scrolling. A genuine TOC / search jump
    /// targets a DIFFERENT index, so it still scrolls.
    @State private var lastScrolledChapterIndex: Int? = nil
    /// True while a slide animation is in flight. Guards advancePage/retreatPage
    /// so a rapid second tap cannot fire a no-animation turn on top of the
    /// in-progress animation (the "flips twice, second one without animation" bug).
    @State private var isPageTurning: Bool = false
    /// Tracks direction of the last page turn for asymmetric transition.
    @State private var pageDirection: PageDirection = .forward
    /// Timestamp of last page turn — debounces rapid taps in all turn
    /// styles, not just slide (slide uses isPageTurning, none/flip had no guard).
    @State private var lastPageTurnAt: Date = .distantPast
    /// Minimum seconds between page turns — 500 ms covers rapid double-taps
    /// and the SpatialTapGesture + UIPanGestureRecognizer window where both
    /// fire for the same swipe gesture.
    private let pageTurnDebounce: TimeInterval = 0.5
    /// Non-nil when retreating across a chapter boundary: holds the chapter.id
    /// we expect to land on so the last-page snap fires exactly once for that
    /// chapter and never bleeds into subsequent navigations.
    @State private var jumpToLastPageForChapterId: String? = nil
    @FocusState private var paginatedFocus: Bool
    /// Last known container size — used to detect orientation changes
    /// and recompute the page index so the reader stays on the same
    /// text passage after rotation.
    @State private var lastContainerSize: CGSize = .zero
    /// Cumulative plain-text character offset at the top of the page
    /// the user was reading before a repagination. Used to find the
    /// equivalent page in the new pagination.
    @State private var textOffsetAtCurrentPage: Int = 0

    // Apple Books pattern: page height is FROZEN once, then held constant
    // across tab-bar visibility changes. The host may vary
    // `chromeTopInset` + `chromeBottomInset` with chrome visibility so a
    // hidden chrome state does not leave large empty bands.
    //
    // `stableBodyHeight` is seeded on first appear and re-seeded only when
    // the container *width* changes (= rotation). Height-only changes
    // (status-bar or safe-area animations) are intentionally ignored to
    // preserve the "zero reflow" invariant.
    @State private var stableBodyHeight: CGFloat = 0

    // Frozen chrome insets for pagination. The host (InstantReaderView)
    // passes `chromeTopInset`/`chromeBottomInset` that drop to 0 when chrome
    // hides — feeding those live values into the page-size math repaginated
    // the chapter on every chrome toggle, so the visible page's slice changed
    // and the text snapped (flicker). Chrome is a true overlay in fixed-margin
    // mode, so the text corridor must stay constant regardless of chrome
    // visibility. We freeze the first non-zero inset pair and paginate against
    // those forever; the live insets still drive the page *position* padding.
    @State private var frozenChromeTopInset: CGFloat = 0
    @State private var frozenChromeBottomInset: CGFloat = 0

    /// `true` while the reader tracks the audio's `currentSentenceId`
    /// — auto-pages and highlights the active sentence. Flipped to
    /// `false` when the user manually advances / retreats a page or
    /// scrolls, so the audio doesn't yank the page out from under
    /// them. A floating "resume" button restores tracking.
    @State private var isFollowing: Bool = true

    // Debounced settings — updated 200ms after sliders stop moving.
    @State private var debouncedFontSize: CGFloat = 0
    @State private var debouncedLineSpacing: Double = 0
    @State private var debouncedMargin: Double = 0
    @State private var debouncedColumnWidth: Double = 0
    // Single in-flight task per slider — cancelled before reassignment
    // so the last-value-wins guarantee is by cancellation, not by luck
    // of scheduling. Without this, dragging a slider piles up dozens of
    // sleeping tasks that all eventually fire in unpredictable order
    // and can leave the reader stuck on an intermediate value.
    @State private var fontDebounceTask: Task<Void, Never>?
    @State private var lineSpacingDebounceTask: Task<Void, Never>?
    @State private var marginDebounceTask: Task<Void, Never>?
    @State private var columnWidthDebounceTask: Task<Void, Never>?
    /// Debounce for `publishReadingRatio`: burst-swipes used to write
    /// `UserDefaults` twice on every page turn (one for ratio, one for
    /// sentenceId). Coalesced into a single delayed write so a
    /// 5-pages-in-2-seconds swipe sequence triggers one write at the
    /// end of the burst, not 10 prefs-daemon round-trips on main.
    @State private var publishRatioTask: Task<Void, Never>?
    /// In-flight task that polls paginationCache.pages to snap to the
    /// last page after retreating across a chapter boundary. Stored so
    /// it can be cancelled when the user navigates again before it fires.
    @State private var jumpToLastPageTask: Task<Void, Never>?
    @State private var pageTurnResetTask: Task<Void, Never>?
    /// Page index to display from lastValidPages during a chapter transition.
    /// Always 0 for forward crossings so the freeze-frame shows page 0 of the
    /// departing chapter (neutral), not its final page (confusing "77/77" flash).
    @State private var chapterTransitionDisplayPage: Int = 0
    /// Memoised pagination result. `Paginator.paginateAttributed`
    /// builds a full TextKit stack (`NSTextStorage` + `NSLayoutManager`
    /// + `NSTextContainer`) and walks the entire chapter — hundreds of
    /// ms for a 30 K-char payload. Every chrome toggle / slider drag /
    /// rotation re-evaluates the GeometryReader body, which would
    /// otherwise re-paginate from scratch each time. Cache keyed on
    /// the inputs that actually change the layout; cleared on chapter
    /// change.
    /// Class-based pagination cache. The previous `@State` pair
    /// (`paginatedPages: [NSAttributedString]` + `paginatedCacheKey:
    /// String?`) had to be written from a `Task { @MainActor in ...
    /// paginatedPages = pages }` because mutating @State from inside
    /// a body-evaluated function is a SwiftUI red flag. Result:
    /// every cache miss enqueued a Task; until that Task ran the
    /// stored key was stale, so subsequent body re-evals also
    /// missed → another Paginator call → another Task. The pile of
    /// Tasks each invalidated body when they finally fired, causing
    /// visible flicker on swipe + occasional landing on the wrong
    /// page (the freshly-computed pages were correct, but the body
    /// re-eval that came AFTER several pending Tasks saw the
    /// last-written value of `currentPage` against an out-of-date
    /// `pages.count`).
    ///
    /// A reference-type cache (`@State` of a `final class`) is the
    /// idiomatic SwiftUI escape hatch: SwiftUI watches the *identity*
    /// of the reference, so field mutations don't trigger view
    /// invalidation — we can update the cache synchronously from
    /// inside `body` without re-firing.
    private final class PaginationCache {
        var pages: [NSAttributedString] = []
        var key: String?
        /// Last non-empty page array. In page-curl mode, this is shown
        /// while a chapter transition re-paginates the new chapter,
        /// preventing the PVC from receiving an empty array and briefly
        /// revealing the background (which looks like the TOC or index).
        var lastValidPages: [NSAttributedString] = []
    }
    @State private var paginationCache = PaginationCache()
    /// Bumped each time `renderedAttributed` is repopulated by the
    /// `.task(id: renderedAttributedKey)`. Used as a cheap identity
    /// for the pagination memo cache — `AttributedString.description`
    /// (the previous key component) materialised the entire formatted
    /// debug representation per body eval (~50–200K alloc + String
    /// hash for a 30K-char chapter) BEFORE the cache lookup happened,
    /// defeating the memo entirely. An incrementing Int is free.
    @State private var renderVersion: Int = 0

    private enum PageDirection { case forward, backward }
    private let pageVerticalPadding: CGFloat = 12
    private var hiddenChromeTopCompaction: CGFloat { chromeVisible ? 0 : 72 }

    /// Per-chapter HTML render cache. Re-populated when `chapter.id`
    /// changes or when any settings field consumed by the renderer
    /// mutates (see `renderedAttributedKey`). Nil = use plain-text
    /// fallback (either because the EPUB had no HTML or the
    /// importer failed).
    @State private var renderedAttributed: AttributedString? = nil
    /// Identity used to invalidate `renderedAttributed`. Combines the
    /// chapter id with every settings field the renderer reads, so
    /// flipping an override toggle triggers a re-parse the same way
    /// switching chapter does.
    private var renderedAttributedKey: String {
        // Numbers stringified so we get cheap value equality.
        let s = settings
        return [
            chapter.id,
            s.readerFontFamily.rawValue,
            String(format: "%.0f", s.readerPointSize),
            s.readerTheme.rawValue,
            s.readerOverrideFontFamily.description,
            s.readerOverrideFontSize.description,
            s.readerOverrideColours.description,
            s.readerBoldOverride.description,
            s.readerSuppressItalic.description,
            String(format: "%.2f", s.readerLetterSpacing),
            String(format: "%.2f", s.readerWordSpacing),
            s.readerTextAlignment.rawValue,
        ].joined(separator: "|")
    }

    init(
        chapter: EbookFulltext.Chapter,
        spans: [SentenceSpan],
        currentSentenceId: String?,
        onJumpToSentence: ((SentenceSpan) -> Void)? = nil,
        onAdvanceChapter: (() -> Bool)? = nil,
        onPreviousChapter: (() -> Bool)? = nil,
        onCenterTap: (() -> Void)? = nil,
        chromeVisible: Bool = true,
        onAutoHideChrome: (() -> Void)? = nil,
        onRestoreChrome: (() -> Void)? = nil,
        onLinkTap: ((URL) -> Bool)? = nil,
        onJumpToPlayerPosition: (() -> Void)? = nil,
        playerChapterLabel: String? = nil,
        chromeTopInset: CGFloat = 0,
        chromeBottomInset: CGFloat = 0,
        useStableBodyHeight: Bool = false,
        bookChapters: [EbookFulltext.Chapter]? = nil,
        onScrolledToChapter: ((Int) -> Void)? = nil,
        onLastPageLanded: (() -> Void)? = nil,
        startAtLastPage: Bool = false
    ) {
        self.chapter = chapter
        self.spans = spans
        self.currentSentenceId = currentSentenceId
        self.onJumpToSentence = onJumpToSentence
        self.onAdvanceChapter = onAdvanceChapter
        self.onPreviousChapter = onPreviousChapter
        self.onCenterTap = onCenterTap
        self.chromeVisible = chromeVisible
        self.onAutoHideChrome = onAutoHideChrome
        self.onRestoreChrome = onRestoreChrome
        self.onLinkTap = onLinkTap
        self.onJumpToPlayerPosition = onJumpToPlayerPosition
        self.playerChapterLabel = playerChapterLabel
        self.chromeTopInset = chromeTopInset
        self.chromeBottomInset = chromeBottomInset
        self.useStableBodyHeight = useStableBodyHeight
        self.bookChapters = bookChapters
        self.onScrolledToChapter = onScrolledToChapter
        self.onLastPageLanded = onLastPageLanded
        // Seed the last-page jump immediately so the very first render
        // of this ReaderView (after a backward chapter crossing) lands
        // on the last page instead of page 0. The @State is initialised
        // here (before any body evaluation) so it is not subject to the
        // race that occurs when the parent sets an external flag and the
        // SwiftUI render cycle zeroes @State on .id-based recreation.
        if startAtLastPage {
            _jumpToLastPageForChapterId = State(initialValue: "__pending__")
            // Pre-seed currentPage to Int.max so TextKitPageView.makeUIViewController
            // uses clampedPage = pages.count - 1 the moment pages arrive, without
            // any navigation animation. The jumpToLastPageTask in onAppear will then
            // normalise Int.max → pages.count - 1 silently (same visual page, no hop).
            _currentPage = State(initialValue: Int.max)
        }
        FlickerProbe.shared.log("ReaderView.init chapter.id=\(chapter.id) startAtLastPage=\(startAtLastPage)")
    }

    var body: some View {
        // CRITICAL: explicitly touch every settings property the
        // child views consume so Observation tracks them at THIS
        // body's level. Without these reads, GeometryReader's
        // content closure (the one inside `paginatedContent`) is the
        // only place that touched `readerLineSpacing` / `readerMargin`
        // / `readerColumnWidth`, and SwiftUI's Observation tracker
        // would invalidate only the GeometryReader sub-body — not
        // the surrounding chrome (toolbar pickers, background
        // colour). Reading them here guarantees the whole reader
        // re-renders on every change, fixing the long-standing
        // "settings only apply on next page turn" bug.
        _ = settings.readerFontSize
        _ = settings.readerFontFamily
        _ = settings.readerTheme
        _ = settings.readerLayout
        _ = settings.readerLineSpacing
        _ = settings.readerMargin
        _ = settings.readerColumnWidth
        _ = settings.readerOverrideFontFamily
        _ = settings.readerOverrideFontSize
        _ = settings.readerOverrideColours
        _ = settings.readerBoldOverride
        _ = settings.readerSuppressItalic
        _ = settings.readerLetterSpacing
        _ = settings.readerWordSpacing
        _ = settings.pageTurnStyle
        _ = settings.readerTextAlignment
        _ = settings.readerShowPageNumbers
        return VStack(spacing: 0) {
            // No inline toolbar: the host (InstantReaderView /
            // PlayerReaderView) already exposes search in its nav-bar
            // ToolbarItem, so a second magnifier here was redundant and
            // ate vertical reading area.
            switch settings.readerLayout {
            case .scrolling:
                if let bookChapters, bookChapters.count > 1 {
                    singleChapterScroll(chapters: bookChapters)
                } else {
                    scrollingContent()
                }
            case .paginated: paginatedContent
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ContainerSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ContainerSizeKey.self) { newSize in
            if sizeChangedMeaningfully(from: lastContainerSize, to: newSize) {
                lastContainerSize = newSize
            }
        }
        .background(themeBackground)
        .foregroundStyle(themeForeground)
        // Force all SwiftUI controls within the reader (pickers, menus,
        // sheets) to inherit a color scheme that matches the reader
        // background. Dark / Black themes → .dark so system materials and
        // dropdown text are legible. Warm themes → .light. Custom → nil
        // (follows OS). This does NOT affect the navigation bar, tab bar,
        // or any UI outside this view.
        .modifier(ReaderColorSchemeModifier(theme: settings.readerTheme))
        .compatOnChange(of: chapter.id) { _ in
            // Landing page for the new chapter. On a forward crossing we land
            // on page 0; on a BACKWARD crossing (retreat) we must land on the
            // previous chapter's LAST page. Seed `currentPage` accordingly
            // BEFORE the new pages arrive so `TextKitPageView`'s token-change
            // re-seed (animated:false) presents the correct page directly. The
            // old code zeroed to 0 and then a polling task snapped to the last
            // page afterwards — that second hop re-navigated animated, which is
            // the wrong-page flash the user saw when crossing to the previous
            // chapter. `Int.max` clamps to the last page the instant pages land.
            let wantsLastPage = jumpToLastPageForChapterId == "__pending__"
            currentPage = wantsLastPage ? Int.max : 0
            FlickerProbe.shared.log("ReaderView.onChange(chapter.id) FIRED chapter.id=\(chapter.id) wantsLastPage=\(wantsLastPage)")
            // Invalidate the chapter-id tag so the footer is suppressed until
            // compatOnChange(of: currentPage) stamps it with the new chapter.id.
            // This closes the gap between body() receiving new chapter and this
            // onChange resetting currentPage — the true cause of the "77/77" flash.
            currentPageChapterId = ""
            // Always freeze the transition frame at page 0 for forward crossings
            // (neutral freeze — first page of departing chapter). For backward
            // crossings we still show page 0 as a generic freeze; the real last
            // page of the new chapter is revealed once pagination completes via
            // the jumpToLastPageTask. This avoids the "77/77" flash that appeared
            // when lastValidPages was kept at the departing chapter's last page.
            chapterTransitionDisplayPage = 0
            isPageTurning = false
            renderedAttributed = nil
            // Clear both key AND pages so livePages() returns [] immediately on
            // the next body eval — preventing the departing chapter's 77 pages
            // from being used as effectivePages for even one frame with the old
            // currentPage=77, which was the "77/77" flash before usingStalePages
            // kicked in. lastValidPages keeps the freeze-frame content.
            paginationCache.pages = []
            paginationCache.key = nil
            // ReaderView now retains its identity across chapter swaps. A
            // forward crossing can keep currentPage at 0, so no currentPage
            // onChange fires to stamp the chapter tag; stamp it explicitly.
            // The footer remains hidden while usingStalePages is true.
            currentPageChapterId = chapter.id
            // Retain the currently visible slices only as a hold frame while
            // the target chapter's final attributed pagination is prepared.
            // TextKitPageView is explicitly fed `finalPages` below, never this
            // hold array, so it cannot seed a new chapter from stale slices.
            // Retreat: refine the `Int.max` sentinel down to the real last
            // index once pagination stabilises, so the binding holds a sane
            // value for everything downstream (page-number footer, persisted
            // position). No animated hop occurs — the seed already showed the
            // last page; this only normalises the stored index.
            if wantsLastPage {
                jumpToLastPageForChapterId = nil
                jumpToLastPageTask?.cancel()
                jumpToLastPageTask = Task { @MainActor in
                    // Wait up to 3 s for the paginator to produce pages.
                    // Poll until the full page count stabilises: two
                    // consecutive reads must agree to avoid snapping to
                    // a partially-built array (which would land on page 2
                    // of a 3-page chapter instead of the last page).
                    var prevCount = 0
                    for _ in 0..<30 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if Task.isCancelled { return }
                        let p = paginationCache.pages
                        if !p.isEmpty && p.count == prevCount {
                            // Force unconditionally — see the matching comment
                            // in the .onAppear jumpToLastPageTask above for why
                            // the `currentPage == Int.max` guard is unsafe.
                            currentPage = p.count - 1
                            onLastPageLanded?()
                            return
                        }
                        prevCount = p.count
                    }
                    onLastPageLanded?()
                }
            }
        }
        .task(id: renderedAttributedKey) {
            // `NSAttributedString.html` importer is main-thread-only
            // (WebKit-backed). Each call costs 50–500 ms for a 30 K-char
            // chapter, so we ensure exactly ONE parse per identity change.
            // The previous belt-and-suspenders `compatOnChange(of:
            // settings.readerTheme/.readerOverrideColours)` doubled the
            // parse on every theme toggle — removed; if the theme-while-
            // sheet-open bug resurfaces, fix it via a `renderVersion`
            // token bumped from the sheet, NOT a parallel re-render path.
            renderedAttributed = renderHtmlForChapter()
            renderVersion &+= 1
        }
        .onAppear {
            debouncedFontSize = settings.readerPointSize
            debouncedLineSpacing = settings.readerLineSpacing
            debouncedMargin = settings.readerMargin
            debouncedColumnWidth = settings.readerColumnWidth
            // When .id(chapter.id) recreates the view for a backward crossing,
            // onChange(of: chapter.id) never fires. The init already seeded
            // currentPage = Int.max (clamped to last page by TextKitPageView).
            // Poll until pages stabilise, then normalise the sentinel so
            // downstream (footer, position persistence) sees a real index.
            // Only write if still Int.max — avoids re-navigating if the user
            // already turned a page while the task was running.
            FlickerProbe.shared.log("ReaderView.onAppear chapter.id=\(chapter.id) jumpFlag=\(jumpToLastPageForChapterId ?? "nil") currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage))")
            if jumpToLastPageForChapterId == "__pending__" {
                jumpToLastPageForChapterId = nil
                jumpToLastPageTask?.cancel()
                jumpToLastPageTask = Task { @MainActor in
                    var prevCount = 0
                    for attempt in 0..<30 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if Task.isCancelled { return }
                        let p = paginationCache.pages
                        FlickerProbe.shared.log("jumpToLastPageTask poll#\(attempt) chapter.id=\(chapter.id) p.count=\(p.count) prevCount=\(prevCount) currentPage=\(currentPage == Int.max ? "MAX" : String(currentPage))")
                        if !p.isEmpty && p.count == prevCount {
                            // Force the last page unconditionally — do NOT gate
                            // on `currentPage == Int.max`. On-device logging
                            // (flicker-debug.log) proved `currentPage` can get
                            // reset to 0 by an unrelated SwiftUI re-render
                            // between this Task being armed and settling here,
                            // even though `jumpToLastPageForChapterId ==
                            // "__pending__"` (the actual retreat intent,
                            // captured before spawning this Task) survived
                            // untouched — the `== Int.max` guard was silently
                            // no-op'ing the correction every time that
                            // happened, reproducing "retreat lands on page 1".
                            // Being inside this Task at all already proves the
                            // user retreated and wants the last page; a manual
                            // page turn during the ~100-300ms settle window is
                            // a much rarer edge case than this main bug.
                            currentPage = p.count - 1
                            FlickerProbe.shared.log("jumpToLastPageTask SETTLED chapter.id=\(chapter.id) currentPage=\(currentPage) (last of \(p.count))")
                            onLastPageLanded?()
                            return
                        }
                        prevCount = p.count
                    }
                    FlickerProbe.shared.log("jumpToLastPageTask TIMED OUT chapter.id=\(chapter.id)")
                    onLastPageLanded?()
                }
            }
        }
        .compatOnChange(of: settings.readerFontSize) { _ in
            let v = settings.readerPointSize
            fontDebounceTask?.cancel()
            fontDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedFontSize = v
            }
        }
        .compatOnChange(of: settings.readerLineSpacing) { new in
            lineSpacingDebounceTask?.cancel()
            lineSpacingDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedLineSpacing = new
            }
        }
        .compatOnChange(of: settings.readerMargin) { new in
            marginDebounceTask?.cancel()
            marginDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedMargin = new
            }
        }
        .compatOnChange(of: settings.readerColumnWidth) { new in
            columnWidthDebounceTask?.cancel()
            columnWidthDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedColumnWidth = new
            }
        }
        .onDisappear {
            // Free any in-flight debounce tasks when the reader is torn
            // down so they don't write to a freed @State (no crash —
            // SwiftUI handles that — but wasteful and shows up in
            // Instruments as zombie tasks).
            fontDebounceTask?.cancel()
            lineSpacingDebounceTask?.cancel()
            marginDebounceTask?.cancel()
            columnWidthDebounceTask?.cancel()
            publishRatioTask?.cancel()
            jumpToLastPageTask?.cancel()
            pageTurnResetTask?.cancel()
        }
    }

    /// Build the chapter's AttributedString lazily off the main hot
    /// path. Returns nil if the chapter has no HTML payload (older
    /// cache entries, plain-text-only fixtures) so the caller falls
    /// back to the existing plain-text rendering.
    @MainActor
    private func renderHtmlForChapter() -> AttributedString? {
        guard let html = chapter.html, !html.isEmpty else { return nil }
        return EpubHtmlRenderer.render(
            html: html, css: chapter.css, settings: settings,
            fontDirectoryURL: epubFontDirectory
        )
    }

    // MARK: Layout helpers

    /// HIG-floored horizontal text margin. Apple Books uses 16pt as the
    /// portrait-iPhone minimum; tighter values clip first/last glyphs
    /// into the screen edge — reported 2026-05-12 when an old build
    /// allowed 12pt and a portrait paragraph rendered outside the safe
    /// content area. The clamp is applied here (and at the model layer
    /// in `AppSettings.readerMargin`) so stale persisted values from
    /// older installs get coerced on first render too.
    private var effectiveReaderMargin: CGFloat {
        effectiveReaderMargin(for: lastContainerSize)
    }

    /// Landscape-aware margin. Apple Books widens margins ~40% in
    /// landscape to keep line lengths comfortable on the wider screen.
    /// On regular-width devices (iPad) the extra padding is unnecessary
    /// because `readerColumnWidth` already constrains the text block.
    private func effectiveReaderMargin(for size: CGSize) -> CGFloat {
        // User explicitly asked for maximum text silhouette — push the
        // margin floor down to 12pt (was 16pt, the Apple Books portrait
        // minimum). 12pt still keeps glyph descenders/diacritics clear of
        // the screen edge on iPhone SE.
        let base = max(12, CGFloat(settings.readerMargin))
        let isLandscape = size.width > size.height
        let isCompactWidth = (horizontalSizeClass == .compact)
        if isLandscape && isCompactWidth {
            // iPhone landscape: slight widen (~25%) so the column doesn't
            // stretch to a 90-char line. Floor at 18pt.
            return max(18, round(base * 1.25))
        }
        return base
    }

    // MARK: Scrolling content

    private func scrollingContent(
        onZoneTap: ((ReaderTapZone) -> Void)? = nil,
        onSwipe: ((ReaderSwipeDirection) -> Void)? = nil
    ) -> some View {
        // Scroll mode now uses the same TextKit-backed renderer as
        // paginated mode (`AttributedPageView` with `scrollable: true`).
        // The previous `LazyVStack` of `sentenceRow`s discarded every
        // EPUB CSS attribute (font family overrides, italics, bold,
        // foreground colour, paragraph indent) — `sentenceText` only
        // read the plain `span.text` and forced `bodyFont`. It also
        // surfaced a yellow highlight on every sentence whenever the
        // AudioPlayer set `currentSentenceId`, even before the user
        // hit play. UITextView with the full attributed string keeps
        // typography fidelity and drops the highlight entirely.
        GeometryReader { geo in
            let margin = effectiveReaderMargin(for: geo.size)
            let effectiveColumnWidth = min(
                settings.readerColumnWidth,
                geo.size.width - 2 * margin
            )
            let effectiveFontSize: CGFloat = debouncedFontSize > 0 ? debouncedFontSize : settings.readerPointSize
            let effectiveLineSpacing: Double = debouncedLineSpacing > 0 ? debouncedLineSpacing : settings.readerLineSpacing
            VStack(alignment: .leading, spacing: 0) {
                AttributedPageView(
                    attributed: scrollingAttributedString(
                        fontSize: effectiveFontSize,
                        lineSpacing: effectiveLineSpacing
                    ),
                    width: effectiveColumnWidth,
                    scrollable: true,
                    onLinkTap: onLinkTap,
                    onZoneTap: onZoneTap ?? handleScrollZoneTap,
                    onSwipe: onSwipe
                )
                // Give the native UITextView a finite viewport inside the
                // VStack. Without this explicit height, GeometryReader may
                // receive its 10pt proposal and the content has no scroll
                // corridor on a physical iPhone.
                .frame(height: geo.size.height)
                .padding(.horizontal, margin)
                .padding(.bottom, chromeBottomInset + 16)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .compatHorizontalSafeAreaPadding(0)
    }

    /// TextKit owns the reading surface in scroll mode. Route non-link taps
    /// directly instead of layering a SwiftUI gesture over UITextView; the
    /// latter can lose the first tap to UIKit's internal recognizers.
    private func handleScrollZoneTap(_ zone: ReaderTapZone) {
        // A simple non-link tap is chrome-only in every zone. Chapter
        // navigation in scroll mode is explicit (swipe/footer), never an
        // accidental consequence of touching the reading surface.
        onCenterTap?()
    }

    /// Build the NSAttributedString rendered in scroll mode: the
    /// pre-rendered EPUB attributed string when available, otherwise a
    /// plain wrapper around the chapter text with the user's font /
    /// spacing settings. Same fallback flow as paginated mode so the
    /// two layouts look identical when scrolling vs paging.
    private func scrollingAttributedString(
        fontSize: CGFloat,
        lineSpacing: Double
    ) -> NSAttributedString {
        #if canImport(UIKit) || canImport(AppKit)
        if let rendered = renderedAttributed {
            return NSAttributedString(rendered)
        }
        let plain = spans.map(\.text).joined(separator: "\n\n")
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(lineSpacing)
        return NSAttributedString(
            string: plain,
            attributes: [
                .font: bodyPlatformFont(size: fontSize),
                .paragraphStyle: para,
            ]
        )
        #else
        return NSAttributedString(string: spans.map(\.text).joined(separator: "\n\n"))
        #endif
    }

    // MARK: Single-chapter scroll (book-aware)

    /// Scroll mode used to render the ENTIRE book as one continuous
    /// `ScrollView`/`LazyVStack` (one cell per chapter). Even though the
    /// `LazyVStack` only materialised cells near the viewport, the
    /// `ForEach` still iterated over every chapter in the book and kept
    /// their identity alive in the hierarchy — on large books this was
    /// perceived as slow/heavy (reported 2026-07-08). Scroll mode now
    /// shows exactly ONE chapter at a time — free scroll *within* that
    /// chapter (`scrollingContent`, unchanged), and an EXPLICIT action
    /// (edge tap or the prev/next footer buttons) to cross a chapter
    /// boundary, mirroring the tap-to-turn interaction paginated mode
    /// already uses but without paginating the text itself.
    ///
    /// Paginated mode (`paginatedContent` / `TextKitPageView`) is
    /// UNTOUCHED — this function only affects `.scrolling` layout.
    ///
    /// Buffering: before rendering, this pre-populates
    /// `BookChapterRenderCache` for the previous/next chapter in the
    /// background so `advanceChapter`/`retreatChapter` (and audio
    /// auto-advance) never show a re-parse flicker — the neighbour's
    /// `NSAttributedString` is usually already cached by the time the
    /// user gets there.
    @ViewBuilder
    private func singleChapterScroll(chapters: [EbookFulltext.Chapter]) -> some View {
        GeometryReader { geo in
            let margin = effectiveReaderMargin(for: geo.size)
            let columnWidth = min(settings.readerColumnWidth, geo.size.width - 2 * margin)
            let fontSize: CGFloat = debouncedFontSize > 0 ? debouncedFontSize : settings.readerPointSize
            let lineSpacing: Double = debouncedLineSpacing > 0 ? debouncedLineSpacing : settings.readerLineSpacing
            ZStack(alignment: .bottom) {
                scrollingContent(onZoneTap: { _ in
                    // Simple taps toggle chrome in every horizontal zone.
                    // Chapter navigation is reserved for horizontal swipes
                    // and the explicit footer controls.
                    onCenterTap?()
                }, onSwipe: { direction in
                    switch direction {
                    case .left:
                        advanceChapter(chapters: chapters)
                    case .right:
                        retreatChapter(chapters: chapters)
                    }
                })
                    .id(chapter.id)
                chapterNavFooter(chapters: chapters)
                    .padding(.bottom, chromeBottomInset + 6)
            }
            .compatOnChange(of: chapter.id) { _ in
                prefetchNeighbours(chapters: chapters, columnWidth: columnWidth, margin: margin, fontSize: fontSize, lineSpacing: lineSpacing)
            }
            .onAppear {
                lastScrolledChapterIndex = chapter.zeroBasedEpubIndex
                prefetchNeighbours(chapters: chapters, columnWidth: columnWidth, margin: margin, fontSize: fontSize, lineSpacing: lineSpacing)
            }
            // Auto-follow: audio advanced to a different chapter — cross
            // the boundary explicitly (this is scroll mode, not a
            // continuous multi-chapter list, so "jump to sentence" now
            // means "switch chapter", same mechanic as paginated mode's
            // `onAdvanceChapter`/`onPreviousChapter` callbacks).
            .compatOnChange(of: currentSentenceId) { newId in
                guard isFollowing, let newId,
                      let colon = newId.firstIndex(of: ":"),
                      let idx = Int(newId[newId.startIndex..<colon]) else { return }
                let target = max(0, idx - 1)
                guard target != chapter.zeroBasedEpubIndex else { return }
                if target > chapter.zeroBasedEpubIndex {
                    _ = onAdvanceChapter?()
                } else {
                    _ = onPreviousChapter?()
                }
                lastScrolledChapterIndex = target
                onScrolledToChapter?(target)
            }
        }
    }

    /// Explicit "next chapter" action for scroll mode — same contract as
    /// `onAdvanceChapter` in paginated mode (host swaps `chapter`/`spans`).
    private func advanceChapter(chapters: [EbookFulltext.Chapter]) {
        guard let next = InstantReaderIndexMapper.nextEpubIndex(
            after: chapter.zeroBasedEpubIndex, in: chapters
        ), onAdvanceChapter?() == true else { return }
        lastScrolledChapterIndex = next
        onScrolledToChapter?(next)
    }

    /// Explicit "previous chapter" action for scroll mode.
    private func retreatChapter(chapters: [EbookFulltext.Chapter]) {
        guard let previous = InstantReaderIndexMapper.previousEpubIndex(
            before: chapter.zeroBasedEpubIndex, in: chapters
        ), onPreviousChapter?() == true else { return }
        lastScrolledChapterIndex = previous
        onScrolledToChapter?(previous)
    }

    /// Small floating footer offering explicit chapter-to-chapter
    /// navigation, mirroring the "toque na lateral ou botão de próximo
    /// capítulo" request — the edge-tap zones above are the fast path,
    /// this is the discoverable one for users who don't know the zones
    /// exist yet (same rationale as paginated mode's page footer).
    private func chapterNavFooter(chapters: [EbookFulltext.Chapter]) -> some View {
        let idx = chapter.zeroBasedEpubIndex
        let ordinal = InstantReaderIndexMapper.ordinal(forEpubIndex: idx, in: chapters) ?? 1
        return HStack {
            Button {
                retreatChapter(chapters: chapters)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(InstantReaderIndexMapper.previousEpubIndex(before: idx, in: chapters) == nil)
            Spacer()
            Text("\(ordinal) / \(chapters.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                advanceChapter(chapters: chapters)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(InstantReaderIndexMapper.nextEpubIndex(after: idx, in: chapters) == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 40)
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    /// Pre-populates `BookChapterRenderCache` for the chapter before and
    /// after the current one, off the interaction path, so
    /// `advanceChapter`/`retreatChapter` (and audio auto-advance) paint
    /// the neighbour instantly instead of parsing its HTML on arrival.
    /// Uses the same `renderKey` shape `BookChapterCell` computes so a
    /// prefetched entry is a guaranteed hit when the cell renders it.
    private func prefetchNeighbours(
        chapters: [EbookFulltext.Chapter],
        columnWidth: CGFloat,
        margin: CGFloat,
        fontSize: CGFloat,
        lineSpacing: Double
    ) {
        let idx = chapter.zeroBasedEpubIndex
        let neighbourIndices = [
            InstantReaderIndexMapper.previousEpubIndex(before: idx, in: chapters),
            InstantReaderIndexMapper.nextEpubIndex(after: idx, in: chapters),
        ].compactMap { $0 }
        guard !neighbourIndices.isEmpty else { return }
        let capturedSettings = settings
        let fontDir = epubFontDirectory
        // `EpubHtmlRenderer.render` is main-thread-only (WebKit importer),
        // so this can't be `Task.detached` off the main actor — instead we
        // yield first so the current chapter's own render/layout pass
        // finishes and paints before we spend main-thread time on
        // neighbours the user isn't looking at yet.
        Task { @MainActor in
            for i in neighbourIndices {
                await Task.yield()
                guard let ch = chapters.first(where: { $0.zeroBasedEpubIndex == i }) else { continue }
                let key = BookChapterCell.renderKey(
                    chapter: ch, settings: capturedSettings, fontSize: fontSize, lineSpacing: lineSpacing
                )
                if BookChapterRenderCache.value(for: key) != nil { continue }
                let rendered = BookChapterCell.renderAttributed(
                    chapter: ch, settings: capturedSettings, fontDirectoryURL: fontDir,
                    fontSize: fontSize, lineSpacing: lineSpacing
                )
                BookChapterRenderCache.store(rendered, for: key)
            }
        }
    }

    // MARK: Paginated content

    /// True when the host opted into the Apple Books "fixed margin"
    /// layout by passing non-zero chrome insets (InstantReaderView).
    /// Legacy hosts (PlayerReaderView) leave both at 0 and keep the
    /// live-height layout where chrome is part of the VStack.
    private var usesFixedMargin: Bool {
        useStableBodyHeight || chromeTopInset > 0 || chromeBottomInset > 0
    }

    private var paginatedContent: some View {
        // Two layout modes, picked by whether the host passed chrome insets:
        //
        // FIXED-MARGIN (InstantReaderView — `usesFixedMargin == true`):
        //   Apple Books pattern. The host renders chrome as a ZStack
        //   OVERLAY; `chromeTopInset` / `chromeBottomInset` are its fixed
        //   heights. Pagination uses a FROZEN `stableBodyHeight` minus
        //   those insets, so a chrome toggle never repaginates. The page
        //   ZStack is padded by the insets so text lives in the
        //   chrome-free corridor; hiding chrome just empties the margin.
        //
        // LIVE-HEIGHT (PlayerReaderView — both insets 0):
        //   Chrome is part of the VStack layout, so the reader pane
        //   genuinely resizes when the transport pane shows/hides — the
        //   page budget must follow `geo.size.height` (minus the 76 pt
        //   footer/margin budget) as before.
        //
        // GeometryReader gives the container width always; height comes
        // from `stableBodyHeight` only in fixed-margin mode.
        GeometryReader { geo in
            let margin = effectiveReaderMargin(for: geo.size)
            let effectiveFontSize: CGFloat = debouncedFontSize > 0 ? debouncedFontSize : settings.readerPointSize
            let effectiveLineSpacing: Double = debouncedLineSpacing > 0 ? debouncedLineSpacing : settings.readerLineSpacing
            let effectiveColumnWidth: CGFloat = debouncedColumnWidth > 0 ? CGFloat(debouncedColumnWidth) : settings.readerColumnWidth

            // Body budget. Fixed-margin: frozen height minus the currently
            // visible chrome insets. Live-height:
            // current container height minus the 76 pt footer/margin budget.
            // Footer ("n / total") reserves a fixed strip at the bottom
            // of the ZStack. The paginator must size each page slice to
            // END above this strip; otherwise the last line of text is
            // drawn UNDER the footer and the visible page shows only
            // the tops of those glyphs. When the user disables page
            // numbers in `ReaderSettingsSheet`, the strip collapses to
            // 0 and the paginator reclaims the full body height.
            let footerStripHeight: CGFloat = settings.readerShowPageNumbers ? 30 : 0
            // `pageView` wraps every paginated page in
            // `.padding(.vertical, pageVerticalPadding)` (24 pt total)
            // for Apple Books-style breathing room around the text rectangle.
            // Without discounting it from `textAreaHeight`, the paginator
            // sized slices for the FULL body corridor → TextKit then
            // drew the slice into the corridor MINUS that padding → the last
            // ~1 line of text bled past the visible region (visible
            // as a half-cut "Clara" against the footer pill).
            let pagePaddingV: CGFloat = pageVerticalPadding * 2
            let textAreaHeight: CGFloat = {
                if usesFixedMargin {
                    // Chrome is a true overlay. Paginate against the FROZEN
                    // chrome insets, never the live ones — otherwise hiding
                    // chrome (insets → 0) shrinks the corridor, repaginates,
                    // and the visible page's slice changes mid-toggle (flicker).
                    // The live insets still position the page via `.padding`.
                    let bodyH = stableBodyHeight > 0 ? stableBodyHeight : geo.size.height
                    let topReserve = max(frozenChromeTopInset, chromeTopInset)
                    let bottomReserve = max(frozenChromeBottomInset, chromeBottomInset)
                    return max(120, bodyH - topReserve - bottomReserve - footerStripHeight - pagePaddingV)
                }
                return max(120, geo.size.height - 76 - footerStripHeight - pagePaddingV)
            }()
            let pageBodySize = CGSize(width: geo.size.width, height: textAreaHeight)
            let pages: [NSAttributedString] = {
                // Avoid the temporary plain-text pagination when returning to
                // a previous chapter. Its page count differs from the final
                // EPUB HTML/CSS layout and caused a visible whole-chapter jump.
                guard !(jumpToLastPageForChapterId == "__pending__" && renderedAttributed == nil) else {
                    return []
                }
                return attributedPages(
                    pageSize: pageBodySize,
                    margin: margin,
                    columnWidth: effectiveColumnWidth,
                    headerHeight: 0,
                    fontSize: effectiveFontSize,
                    lineSpacing: effectiveLineSpacing
                )
            }()
            // Hold the last valid page array while the new chapter re-paginates.
            // After onChange(of: chapter.id) clears paginationCache.pages and
            // renderedAttributed, there is a window before the .task populates
            // the new chapter where pages is empty. Without this guard, all
            // paginated modes (slide, none, curl) briefly show chapterTitleHeader
            // or a blank background — visible as a flash.
            // lastValidPages is stale chapter content (departing chapter page 0)
            // and is replaced the moment the new chapter renders.
            let usingStalePages = pages.isEmpty && !paginationCache.lastValidPages.isEmpty
            let effectivePages: [NSAttributedString] =
                pages.isEmpty ? paginationCache.lastValidPages : pages
            // Only a TRULY empty result is a visible flash (the
            // chapterTitleHeader / blank frame the user sees mid chapter
            // switch). Falling back to stale `lastValidPages` is intentional
            // and renders real text, so it is NOT counted — the new chapter
            // replaces it within a frame or two. Wrapped in an immediately-
            // invoked closure so this side-effect is a `let`, legal inside
            // the GeometryReader's @ViewBuilder body.
            let _: Void = {
                #if os(iOS)
                if effectivePages.isEmpty { FlickerProbe.shared.record(.emptyPagesShown) }
                #endif
            }()
            ZStack(alignment: .bottom) {
                if effectivePages.isEmpty {
                    chapterTitleHeader
                        .padding(.horizontal, margin)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    paginatedPageContent(pages: effectivePages, curlPages: pages, containerSize: geo.size, safeArea: geo.safeAreaInsets,
                                         pageOverride: usingStalePages ? chapterTransitionDisplayPage : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // NOTE: no `-hiddenChromeTopCompaction` offset here. It
                        // used to lift the whole page 72 pt when chrome hid,
                        // which pushed the first line under the status bar /
                        // notch. The corridor math (topCorridor) already keeps
                        // the safe area inviolable AND compacts only the chrome
                        // reserve, so the page stays clear of the clock on every
                        // page in both chrome states.

                    // Suppress the page footer whenever the chapter.id has changed
                    // but onChange hasn't yet reset currentPage. This is the true
                    // root cause of the "77/77 → 1/6" flicker: SwiftUI delivers
                    // the new chapter prop to body() BEFORE compatOnChange fires,
                    // so there is always at least one frame where chapter=NEW but
                    // currentPage=OLD(77). currentPageChapterId tracks which chapter
                    // currentPage belongs to; a mismatch means we're in that gap.
                    let footerChapterReady = currentPageChapterId == chapter.id && !usingStalePages
                    if footerChapterReady {
                        let stablePageIndex = stablePageFooterIndex(effectivePages: effectivePages)
                        let stablePageTotal = stablePageFooterTotal(effectivePages: effectivePages)
                        if settings.readerShowPageNumbers, stablePageTotal > 0 {
                            pageFooter(index: stablePageIndex, total: stablePageTotal)
                                .padding(.bottom, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            // Shift the text area downward only for currently visible top
            // chrome, and inset the bottom only for currently visible bottom
            // chrome.
            .padding(.top, chromeTopInset)
            .padding(.bottom, chromeBottomInset)
            .compatFocusable()
            .focused($paginatedFocus)
            .modifier(HideFocusRingModifier())
            .onAppear {
                paginatedFocus = true
                // Seed the stable height once on first appear. This is
                // the SCREEN height captured at launch; subsequent
                // chrome / tab-bar toggles do not change it.
                if stableBodyHeight == 0 {
                    stableBodyHeight = geo.size.height
                }
                // Freeze the chrome reserve the first time we see it visible,
                // so a later chrome-hide (insets → 0) can't shrink the
                // pagination corridor and repaginate the chapter.
                if frozenChromeTopInset == 0, chromeTopInset > 0 {
                    frozenChromeTopInset = chromeTopInset
                }
                if frozenChromeBottomInset == 0, chromeBottomInset > 0 {
                    frozenChromeBottomInset = chromeBottomInset
                }
                lastContainerSize = geo.size
                // When the view is recreated via .id(chapter.id) at the call site,
                // @State resets to its initial value — currentPageChapterId = "".
                // If the user is on page 0 and stays there, compatOnChange(of: currentPage)
                // never fires (no delta), so currentPageChapterId stays "" and the footer
                // guard (currentPageChapterId == chapter.id) is permanently false.
                // Seed it here on appear so the footer shows on page 0 from the start.
                if currentPageChapterId != chapter.id {
                    currentPageChapterId = chapter.id
                }
            }
            .compatOnKeyPressArrowsAndPaging { key in
                handleCompatKey(key, totalPages: pages.count)
            }
            .compatOnChange(of: geo.size) { newSize in
                // Re-seed stableBodyHeight on width change (rotation) OR
                // when the container grows TALLER than the frozen value.
                // The grow case protects against one-time host safe-area
                // changes, while height shrinks are ignored so a chrome
                // toggle never repaginates.
                let widthChanged = abs(newSize.width - lastContainerSize.width) > 2
                let grewTaller = newSize.height > stableBodyHeight + 8
                if widthChanged || grewTaller {
                    stableBodyHeight = newSize.height
                }
                guard sizeChangedMeaningfully(from: lastContainerSize, to: newSize) else { return }
                lastContainerSize = newSize
                // Only re-derive currentPage when the WIDTH changed (real rotation)
                // AND enough time has passed since the last page turn.
                // Height-only oscillations (safe-area, keyboard, UITextView relayout
                // after a page flip) must NOT touch currentPage — findPage would
                // return a stale page because textOffsetAtCurrentPage hasn't been
                // updated yet by onChange(of: currentPage).
                guard widthChanged else { return }
                guard Date().timeIntervalSince(lastPageTurnAt) > 1.0 else { return }
                let rotationPages = livePages(fallback: pages)
                if !rotationPages.isEmpty {
                    let target = findPage(containing: textOffsetAtCurrentPage, in: rotationPages)
                    if target != currentPage {
                        currentPage = target
                    }
                }
            }
            // Keep textOffsetAtCurrentPage in sync whenever the page changes.
            // Use paginationCache.pages (reference type, always current) instead
            // of the `pages` let-binding captured from the body render — that
            // local array can be empty/stale when SwiftUI fires this closure
            // during a concurrent re-render, causing cumulativeOffset to return
            // 0 and resetting the reader to page 0 on the next syncPageToTextOffset.
            .compatOnChange(of: currentPage) { newPage in
                let currentPages = livePages(fallback: pages)
                // Only write textOffsetAtCurrentPage when livePages() returned
                // a non-empty array. During rapid slide turns the paginator can
                // transiently return [] while UIPageViewController re-renders;
                // writing 0 from an empty array causes syncPageToTextOffset
                // (fired by debounced settings observers) to reset currentPage to 0.
                // We check isEmpty on the LIVE cache directly — if paginationCache
                // had real pages, livePages returns them regardless of `pages`.
                guard !paginationCache.pages.isEmpty else { return }
                textOffsetAtCurrentPage = cumulativeOffset(page: newPage, in: currentPages)
                // Track which chapter this currentPage belongs to so the footer
                // can detect the gap between new-chapter body() and onChange().
                currentPageChapterId = chapter.id
                publishReadingRatio(pages: currentPages)
            }
            // Seed the reading-ratio channel on first appear so a play
            // tap during the very first second of reading already has
            // a hint to land on.
            .onAppear { publishReadingRatio(pages: pages) }
            // Auto-follow: when the audio's active sentence changes,
            // jump to whichever page contains it — but only if the
            // user hasn't taken control via swipe / tap / arrow.
            .compatOnChange(of: currentSentenceId) { newId in
                // Safety backstop: if onDidFinishTransition was somehow never
                // delivered (e.g. a dropped UIPageViewController delegate call),
                // isPageTurning could stay true forever. Treat any audio tick
                // arriving more than 1.5 s after the last user turn as a signal
                // that the animation is definitely over.
                if isPageTurning, Date().timeIntervalSince(lastPageTurnAt) > 1.5 {
                    isPageTurning = false
                }
                guard isFollowing, !isPageTurning, let newId else { return }
                guard let span = spans.first(where: { $0.id == newId }) else { return }
                // Read from the live pagination cache, not the `pages` captured
                // by the body. If `pages` is momentarily empty during a
                // concurrent re-render, `pageIndexContaining` returns page 0 and
                // the withAnimation below snaps the reader back to the top mid
                // playback — the "flicker on audio auto-follow" the user saw.
                // Suppressing the snap when the cache is momentarily empty is
                // the fix; a stale/empty array would have collapsed the target
                // to page 0. Not recorded on the probe — this is the expected
                // transient during a concurrent re-render, not a visible glitch.
                let followPages = livePages(fallback: pages)
                guard !followPages.isEmpty else { return }
                guard let target = pageIndexContaining(sentence: span, in: followPages) else { return }
                if target != currentPage {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentPage = target
                    }
                }
            }
            // A font / spacing / margin / column-width change repaginates
            // the chapter, which leaves `currentPage` pointing at a stale
            // index. Re-derive it from the saved text offset so the
            // reading position survives the reflow — the `geo.size`
            // handler above only covers rotation, not a settings-driven
            // repagination.
            .compatOnChange(of: debouncedFontSize) { _ in syncPageToTextOffset(in: livePages(fallback: pages)) }
            .compatOnChange(of: debouncedLineSpacing) { _ in syncPageToTextOffset(in: livePages(fallback: pages)) }
            .compatOnChange(of: debouncedMargin) { _ in syncPageToTextOffset(in: livePages(fallback: pages)) }
            .compatOnChange(of: debouncedColumnWidth) { _ in syncPageToTextOffset(in: livePages(fallback: pages)) }
        }
        .compatHorizontalSafeAreaPadding(0)
        // Floating "resume follow-along" button — visible whenever the
        // reader has wandered off the audio position (manual page turn
        // / swipe / chapter switch), regardless of whether the engine
        // emits per-sentence highlights. Tapping it both restores
        // sentence-level auto-follow AND asks the host to jump back to
        // the audio's chapter (handled outside this view because the
        // chapter list lives in the parent).
        .overlay(alignment: .bottomTrailing) {
            // Pill is shown when EITHER the reader has wandered off
            // the audio (`!isFollowing`) OR the audio simply lives on
            // a different chapter than the reader is viewing
            // (`playerChapterLabel != nil`). The second arm catches
            // the cold-launch case: user opens the reader at chapter
            // 0 while the audio resumed at chapter 5 — `isFollowing`
            // is still true (no manual page turn yet), but the user
            // still needs the divergence cue.
            // The follow-audio pill is part of the reader chrome — it
            // must disappear together with the top/bottom bars on the
            // immersive (chrome-hidden) state. Otherwise the pill
            // floats over the now-fullscreen text and breaks the
            // "tap-to-hide-chrome" mental model.
            if chromeVisible && (!isFollowing || playerChapterLabel != nil) {
                Button {
                    isFollowing = true
                    onJumpToPlayerPosition?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: playerChapterLabel != nil
                              ? "speaker.wave.2.fill"
                              : "arrow.uturn.down")
                        // Two-line label when the audio is on another
                        // chapter: top line is the cue, bottom line
                        // names the chapter. Single line otherwise.
                        if let label = playerChapterLabel, !label.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(L10n.string("reader.nowPlaying"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(label)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                            }
                        } else {
                            Text(L10n.string("reader.followAudio"))
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                }
                .padding(20)
                .frame(minWidth: 44, minHeight: 44, alignment: .center)
                .accessibilityIdentifier("reader.followAudio")
                .accessibilityLabel(
                    playerChapterLabel.map {
                        "\(L10n.string("reader.nowPlaying")): \($0). \(L10n.string("reader.followAudio"))"
                    } ?? L10n.string("reader.followAudio")
                )
                .accessibilityHint(L10n.string("reader.followAudioHint"))
                // Positional transitions are not safe under Reduce
                // Motion (HIG: prefer fade). Drop the slide on users
                // who opted into reduced motion.
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
    }

    /// True when the size delta is large enough to warrant repagination.
    /// Filters out sub-point jitter from keyboard, status bar, etc.
    private func sizeChangedMeaningfully(from old: CGSize, to new: CGSize) -> Bool {
        abs(old.width - new.width) > 2 || abs(old.height - new.height) > 2
    }

    /// The authoritative page array to read from inside a `.compatOnChange`
    /// closure. `paginationCache.pages` (reference type) is always current;
    /// the `pages` value captured by the GeometryReader body can be empty or
    /// stale when SwiftUI fires a closure during a concurrent re-render, which
    /// collapses page lookups to index 0 and flickers the reader back to the
    /// top. Prefer the live cache, fall back to the captured array only when
    /// the cache is momentarily empty. Centralised so every call site uses the
    /// same rule (the bug was each site re-deriving it by hand and one path —
    /// auto-follow — being missed).
    private func livePages(fallback: [NSAttributedString]) -> [NSAttributedString] {
        paginationCache.pages.isEmpty ? fallback : paginationCache.pages
    }

    private func stablePageFooterIndex(effectivePages: [NSAttributedString], pageOverride: Int? = nil) -> Int {
        let total = stablePageFooterTotal(effectivePages: effectivePages)
        guard total > 0 else { return 0 }
        return max(0, min(total - 1, pageOverride ?? currentPage))
    }

    private func stablePageFooterTotal(effectivePages: [NSAttributedString]) -> Int {
        if !paginationCache.pages.isEmpty {
            return paginationCache.pages.count
        }
        if !effectivePages.isEmpty {
            return effectivePages.count
        }
        return paginationCache.lastValidPages.count
    }

    /// Cumulative plain-text character count up to (but not including) the
    /// given page index. Used to bookmark the reading position.
    private func cumulativeOffset(page: Int, in pages: [NSAttributedString]) -> Int {
        guard !pages.isEmpty else { return 0 }
        let clamped = max(0, min(pages.count - 1, page))
        return pages[..<clamped].reduce(0) { $0 + $1.length }
    }

    /// Publishes both reader-position channels:
    ///  - `readerCurrentPageRatio` (Double, 0…1) — char-uniform
    ///    approximation; used when no per-sentence timing is available.
    ///  - `readerCurrentSentenceId` (String) — id of the first
    ///    sentence span on the user's current page. When
    ///    `AudioPlayer` has timing for this chapter (injected via
    ///    `setSentenceTiming`), the divergence dialog prefers this
    ///    precise anchor over the ratio.
    ///
    /// Coalesced via `publishRatioTask`: a burst of page turns only
    /// triggers one UserDefaults round-trip 150 ms after the last
    /// swipe. The previous "write on every turn" pattern was a
    /// prefs-daemon hot path on the main thread — visible in
    /// Instruments as `CFPreferencesAppValueIsForced`.
    private func publishReadingRatio(pages: [NSAttributedString]) {
        let total = pages.reduce(0) { $0 + $1.length }
        guard total > 0 else { return }
        let offset = cumulativeOffset(page: currentPage, in: pages)
        let ratio = max(0, min(1, Double(offset) / Double(total)))
        // Anchor sentence id captured *now* so the eventual write
        // reflects the page we're settling on, not whatever happens
        // to be visible 150 ms later (the user may keep swiping).
        // Find the first sentence whose text appears on the current page by
        // probing the page's attributed string directly. This is immune to the
        // character-space mismatch between NSAttributedString (HTML-rendered)
        // and SentenceSpan.startChar (plain-text offset) that affects EPUBs
        // with CSS/markup — the same approach used by pageIndexContaining().
        let currentPageString = pages.indices.contains(currentPage)
            ? (pages[currentPage].string as NSString)
            : nil
        let anchorSentenceId = spans.first(where: { span in
            guard let pageStr = currentPageString else { return false }
            let probe = String(span.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return !probe.isEmpty && pageStr.range(of: probe).location != NSNotFound
        })?.id

        publishRatioTask?.cancel()
        publishRatioTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            // Route through the coordinator instead of writing
            // UserDefaults directly — the coordinator owns the
            // single debounced mirror to the App Group container,
            // and every play surface observes its `anchor` via
            // @EnvironmentObject.
            readerCoordinator.setPagePosition(ratio: ratio, sentenceId: anchorSentenceId)
        }
    }

    /// Find the page that contains the given cumulative character offset.
    private func findPage(containing offset: Int, in pages: [NSAttributedString]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var cumulative = 0
        for (i, page) in pages.enumerated() {
            cumulative += page.length
            if cumulative > offset { return i }
        }
        return pages.count - 1
    }

    /// Re-derive `currentPage` from `textOffsetAtCurrentPage` after a
    /// settings-driven repagination (font / spacing / margin / column
    /// width) so the reading position doesn't drift by a page.
    private func syncPageToTextOffset(in pages: [NSAttributedString]) {
        guard !pages.isEmpty else { return }
        let target = findPage(containing: textOffsetAtCurrentPage, in: pages)
        if target != currentPage { currentPage = target }
    }

    /// Build the per-page `NSAttributedString` list. Uses the pre-rendered
    /// EPUB AttributedString (which carries the book's CSS fonts, colours,
    /// weight, line spacing) when available; falls back to a synthesised
    /// attributed wrapper around the raw chapter text otherwise.
    private func attributedPages(
        pageSize: CGSize,
        margin: CGFloat,
        columnWidth: CGFloat,
        headerHeight: CGFloat,
        fontSize: CGFloat,
        lineSpacing: Double
    ) -> [NSAttributedString] {
        #if canImport(UIKit) || canImport(AppKit)
        // Build the cache key from every input that actually affects
        // the layout. `renderVersion` is bumped by the `.task(id:)`
        // every time `renderedAttributed` is repopulated, so it's a
        // free O(1) identity for the underlying AttributedString —
        // avoiding the previous `description.hashValue` materialisation
        // which paid 50-200K alloc + String hash per body eval before
        // the cache lookup ever happened (defeating the memo).
        let key = [
            chapter.id,
            String(format: "%.0fx%.0f", pageSize.width, pageSize.height),
            String(format: "%.0f", margin),
            String(format: "%.0f", columnWidth),
            String(format: "%.0f", headerHeight),
            String(format: "%.0f", fontSize),
            String(format: "%.2f", lineSpacing),
            String(renderVersion),
        ].joined(separator: "|")
        if paginationCache.key == key {
            return paginationCache.pages
        }

        let base: NSAttributedString
        if let rendered = renderedAttributed {
            base = NSAttributedString(rendered)
        } else {
            let plain = spans.map(\.text).joined(separator: "\n\n")
            let font = bodyPlatformFont(size: fontSize)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = CGFloat(lineSpacing)
            // Honour the same alignment choice the EPUB renderer
            // applies (default justified). Without this the
            // plain-text fallback (rendered while
            // `renderedAttributed` is still nil — books without
            // HTML or the brief window before .task fires)
            // shows ragged-right text, then flips to justified
            // when the HTML lands.
            para.alignment = settings.readerTextAlignment == .justified
                ? .justified
                : .left
            base = NSAttributedString(string: plain, attributes: [
                .font: font,
                .paragraphStyle: para,
            ])
        }
        let pages = Paginator.paginateAttributed(
            base,
            pageSize: pageSize,
            columnWidth: columnWidth,
            margin: Double(margin),
            headerHeight: headerHeight
        )
        // Synchronous write into the class-based cache (no @State
        // invalidation triggered — see `PaginationCache` doc). The
        // next body eval with the same key short-circuits at the
        // `key == ` check above.
        paginationCache.pages = pages
        paginationCache.key = key
        if !pages.isEmpty {
            paginationCache.lastValidPages = pages
            // New chapter's pages have arrived — the transition freeze-frame
            // window is over. Reset the display-page override so subsequent
            // transient empty states (e.g. rapid settings changes) don't
            // re-pin the footer to page 0 incorrectly.
            chapterTransitionDisplayPage = 0
        }
        return pages
        #else
        return []
        #endif
    }

    #if canImport(UIKit)
    private func bodyPlatformFont(size: CGFloat) -> UIFont {
        switch settings.readerFontFamily {
        case .sans: return .systemFont(ofSize: size)
        case .serif:
            let d = UIFont.systemFont(ofSize: size)
                .fontDescriptor.withDesign(.serif)
                ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: d, size: size)
        case .mono: return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
    #elseif canImport(AppKit)
    private func bodyPlatformFont(size: CGFloat) -> NSFont {
        switch settings.readerFontFamily {
        case .sans: return .systemFont(ofSize: size)
        case .serif: return NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        case .mono: return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
    #endif

    /// Dispatch page rendering to the appropriate animation container
    /// based on `settings.pageTurnStyle`.
    @ViewBuilder
    private func paginatedPageContent(pages: [NSAttributedString], curlPages: [NSAttributedString]? = nil, containerSize: CGSize, safeArea: EdgeInsets = EdgeInsets(), pageOverride: Int? = nil) -> some View {
        let pageIndex = max(0, min(pages.count - 1, pageOverride ?? currentPage))
        switch settings.pageTurnStyle {
        #if os(iOS)
        case .flip:
            pageCurlContent(pages: curlPages ?? pages, containerSize: containerSize, safeArea: safeArea)
        #endif
        case .slide:
            slidePageContent(pages: pages, pageIndex: pageIndex, containerSize: containerSize)
        case .none:
            noAnimationPageContent(pages: pages, pageIndex: pageIndex, containerSize: containerSize)
        #if os(macOS)
        case .flip:
            // macOS doesn't have UIPageViewController; fall back to slide
            slidePageContent(pages: pages, pageIndex: pageIndex, containerSize: containerSize)
        #endif
        }
    }

    #if os(iOS)
    /// Apple Books-style page curl backed by a native TextKit page view.
    /// Pages are raw `NSAttributedString` slices fed straight to a
    /// `UITextView` per page — no SwiftUI `AnyView` snapshot, no
    /// content-identity cache. See `TextKitPageView` for why this fixes
    /// the stale-page / flicker / chapter-skip bugs the old
    /// `PageCurlContainer` had.
    private func pageCurlContent(pages: [NSAttributedString], containerSize: CGSize, safeArea: EdgeInsets) -> some View {
        let margin = effectiveReaderMargin(for: containerSize)
        let columnWidth = min(
            (debouncedColumnWidth > 0 ? CGFloat(debouncedColumnWidth) : settings.readerColumnWidth),
            containerSize.width - 2 * margin
        )
        // Horizontal inset that brackets the (possibly narrower) column.
        // On a phone the column already fills `width - 2*margin`, so this is
        // just `margin`; on a wide iPad it centres the column.
        let sideInset = ReaderLayoutMath.sideInset(containerWidth: containerSize.width, columnWidth: columnWidth, margin: margin)
        // Vertical corridor. The UIKit page controller's safe-area guide is
        // unreliable when hosted under SwiftUI (the host often zeroes the
        // child controller's safe-area insets), so we DO NOT rely on it.
        // Instead we add SwiftUI's known safe-area insets explicitly here
        // and pin the text view to the raw view edges. This guarantees text
        // clears the status bar (clock / battery) and home indicator on
        // every page, not just the first.
        let footerStripHeight: CGFloat = settings.readerShowPageNumbers ? 30 : 0
        let topCorridor = ReaderLayoutMath.topCorridor(
            safeAreaTop: safeArea.top, chromeTop: chromeTopInset,
            pad: pageVerticalPadding, hiddenCompaction: hiddenChromeTopCompaction
        )
        let bottomCorridor = ReaderLayoutMath.bottomCorridor(
            safeAreaBottom: safeArea.bottom, chromeBottom: chromeBottomInset,
            footer: footerStripHeight, pad: pageVerticalPadding
        )
        return TextKitPageView(
            pages: pages,
            chapterToken: chapter.id,
            currentPage: $currentPage,
            columnWidth: columnWidth,
            margin: sideInset,
            topInset: topCorridor,
            bottomInset: bottomCorridor,
            backgroundColor: UIColor(themeBackground),
            onAdvanceChapter: onAdvanceChapter,
            onPreviousChapter: onPreviousChapter,
            onCenterTap: onCenterTap,
            onLinkTap: onLinkTap,
            spans: spans,
            onJumpToSentence: onJumpToSentence,
            onUserPageChange: { isFollowing = false },
            onWillTransition: { isPageTurning = true },
            onDidFinishTransition: { isPageTurning = false },
            onPreviousChapterNeedsLastPage: {
                jumpToLastPageForChapterId = "__pending__"
            }
        )
    }
    #endif

    /// Page renderer for the "slide" turn style — kept as the default
    /// because page-curl needs `UIPageViewController`. We *no longer*
    /// apply `.id(pageIndex)` + `.transition` here: that pair made
    /// SwiftUI tear down the old `pageView` (and the UITextView inside
    /// it) and stand up a new one on every page turn. The new
    /// UITextView's TextKit relayout takes a few frames, during which
    /// the user saw the previous page's text briefly snap back —
    /// the "flicker that corrects after 100ms" the user reported.
    ///
    /// Without `.id`, `AttributedPageView` keeps a single UITextView
    /// instance across page changes and `updateUIView` just rewrites
    /// `attributedText` in place — instant, no relayout flicker.
    /// We lose the slide animation in exchange; reading-mode UX
    /// (Apple Books "scroll" style) does instant flips too, so the
    /// trade-off is acceptable.
    private func slidePageContent(pages: [NSAttributedString], pageIndex: Int, containerSize: CGSize) -> some View {
        return pageView(
            pages: pages,
            pageIndex: pageIndex,
            containerSize: containerSize,
            onSwipePage: { dir in handleSwipe(dir, totalPages: pages.count) }
        )
    }

    private func noAnimationPageContent(pages: [NSAttributedString], pageIndex: Int, containerSize: CGSize) -> some View {
        return pageView(
            pages: pages,
            pageIndex: pageIndex,
            containerSize: containerSize,
            onSwipePage: { dir in handleSwipe(dir, totalPages: pages.count) }
        )
    }

    private func pageLinkHits(
        pages: [NSAttributedString],
        pageIndex: Int,
        columnWidth: CGFloat
    ) -> [(url: URL, rect: CGRect)] {
        #if canImport(UIKit) || canImport(AppKit)
        guard pageIndex >= 0 && pageIndex < pages.count else { return [] }
        return Paginator.linkHits(in: pages[pageIndex], width: columnWidth)
        #else
        return []
        #endif
    }

    /// Glue between `FixedWidthTextView`'s zone classification and the
    /// reader's existing `advancePage` / `retreatPage` / `onCenterTap`
    /// vocabulary.
    private func handleZoneTap(_ zone: ReaderTapZone, totalPages: Int) {
        // Simple taps toggle chrome. Page turns use horizontal swipes or
        // explicit navigation controls, so touching text cannot turn a page.
        onCenterTap?()
    }

    private func handleSwipe(_ direction: ReaderSwipeDirection, totalPages: Int) {
        switch direction {
        case .left:  advancePage(totalPages: totalPages)
        case .right: retreatPage()
        }
    }

    private func pageView(
        pages: [NSAttributedString],
        pageIndex: Int,
        containerSize: CGSize,
        enableReaderGestures: Bool = true,
        onSwipePage: ((ReaderSwipeDirection) -> Void)? = nil
    ) -> some View {
        let margin = effectiveReaderMargin(for: containerSize)
        let attributedSlice = pages[pageIndex]
        let effectiveColumnWidth = min(
            settings.readerColumnWidth,
            containerSize.width - 2 * margin
        )
        return VStack(alignment: .leading, spacing: 0) {
            pageTextBody(
                attributedSlice,
                width: effectiveColumnWidth,
                enableReaderGestures: enableReaderGestures,
                onSwipePage: onSwipePage,
                onZoneTap: enableReaderGestures ? { zone in
                    onCenterTap?()
                } : nil
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, margin)
        .padding(.vertical, pageVerticalPadding)
        .frame(maxWidth: max(200, effectiveColumnWidth + 2 * margin), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .coordinateSpace(name: "readerPage")
        .clipped()
    }

    /// Render the EPUB-styled slice produced by `Paginator.paginateAttributed`.
    /// Because the slice IS a real `NSAttributedString` (not a plain-text
    /// substring), every CSS-driven attribute — font family, weight, italics,
    /// foreground/background colour, paragraph spacing, headings, monospace
    /// code blocks — survives intact. No more mid-word cuts, no more lost
    /// list markers: the TextKit layout pass that built the slice is the
    /// same engine SwiftUI's `Text` uses to render it.
    ///
    /// `enableReaderGestures` must be false when this view is embedded inside
    /// a `UIPageViewController` (page-curl mode). In curl mode the PVC owns
    /// all swipe/tap gestures for page turns; wiring onZoneTap/onSwipe here
    /// causes the SwiftUI binding write (`currentPage += 1`) to race the
    /// PVC's own animation, producing the "flicker between page 1 and current"
    /// bug: the PVC animates forward while simultaneously receiving a
    /// setViewControllers call from the binding update.
    @ViewBuilder
    private func pageTextBody(
        _ slice: NSAttributedString,
        width: CGFloat,
        enableReaderGestures: Bool = true,
        totalPages: Int = 0,
        onSwipePage: ((ReaderSwipeDirection) -> Void)? = nil,
        onZoneTap: ((ReaderTapZone) -> Void)? = nil
    ) -> some View {
        // The UITextView owns the single tap route in paginated mode so
        // center taps toggle chrome exactly once and edge taps turn exactly
        // one page. Links are checked first by FixedWidthTextView.
        //
        // Horizontal swipes are also forwarded to the native recognizer;
        // scroll mode leaves the native vertical pan untouched.
        AttributedPageView(
            attributed: slice,
            width: width,
            onLinkTap: onLinkTap,
            onZoneTap: enableReaderGestures ? onZoneTap : nil,
            onSwipe: enableReaderGestures ? onSwipePage : nil
        )
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func pageFooter(index: Int, total: Int) -> some View {
        Text("\(index + 1) / \(total)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(themeForeground.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // Use theme colour + low opacity instead of system material
            // so the capsule blends with the reader background in dark/
            // black themes rather than rendering as a bright white pill.
            .background(
                Capsule()
                    .fill(themeForeground.opacity(0.1))
            )
            .accessibilityIdentifier("reader.pageIndicator")
            .accessibilityLabel("\(index + 1) of \(total)")
    }

    /// Single invisible tap surface covering the full page area.
    /// Classifies the tap into left / center / right zone by x-position
    /// (each third of the page width). A single gesture prevents the
    /// multi-zone HStack approach from firing more than once per tap —
    /// adjacent Color.clear zones in an HStack can both recognize the
    /// same touch when it lands near a zone boundary.
    @ViewBuilder
    private func tapZones(
        totalPages: Int,
        containerWidth: CGFloat,
        linkHits: [(url: URL, rect: CGRect)],
        textOriginX: CGFloat,
        textOriginY: CGFloat
    ) -> some View {
        if #available(iOS 16, macOS 13, *) {
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(
                    SpatialTapGesture(coordinateSpace: .named("readerPage"))
                        .onEnded { value in
                            let pagePoint = value.location
                            let textPoint = CGPoint(
                                x: pagePoint.x - textOriginX,
                                y: pagePoint.y - textOriginY
                            )
                            if let url = linkHits.first(where: { $0.rect.contains(textPoint) })?.url {
                                if onLinkTap?(url) == true { return }
                            }
                            handleZoneTap(
                                classifyPageZone(x: pagePoint.x, in: containerWidth),
                                totalPages: totalPages
                            )
                        }
                )
        } else {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // iOS 15: no location from plain TapGesture.
                        // Use the center of the zone — not ideal but better
                        // than a split-zone HStack that fires twice.
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleZoneTap(
                                    classifyPageZone(x: value.location.x, in: geo.size.width),
                                    totalPages: totalPages
                                )
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func classifyPageZone(x: CGFloat, in width: CGFloat) -> ReaderTapZone {
        let third = width / 3
        if x < third { return .left }
        if x > width - third { return .right }
        return .center
    }

    /// Compat-key dispatch — returns true when the key was consumed so
    /// the `compatOnKeyPressArrowsAndPaging` shim reports
    /// `.handled`. Older OSes never reach this path (the shim is a
    /// no-op below iOS 17 / macOS 14); macOS keeps page-turn via the
    /// `ScrollWheelPager` modifier and the tap zones.
    private func handleCompatKey(_ key: CompatKey, totalPages: Int) -> Bool {
        switch key {
        case .leftArrow, .pageUp, .k:
            retreatPage()
            return true
        case .rightArrow, .pageDown, .space, .j:
            advancePage(totalPages: totalPages)
            return true
        case .home:
            currentPage = 0
            return true
        case .end:
            currentPage = max(0, totalPages - 1)
            return true
        }
    }

    /// Forward navigation in paginated mode. Within the chapter, walks
    /// `currentPage` forward; on the last page, delegates to the host
    /// view via `onAdvanceChapter` so the next chapter loads. When the
    /// chapter actually changes, the `onChange(of: chapter.id)` modifier
    /// resets `currentPage` to 0.
    private func advancePage(totalPages: Int) {
        // Unified turn guard: isPageTurning covers slide animations;
        // lastPageTurnAt debounces all styles (none/flip had no guard).
        guard !isPageTurning,
              Date().timeIntervalSince(lastPageTurnAt) > pageTurnDebounce else { return }
        lastPageTurnAt = Date()
        jumpToLastPageTask?.cancel()
        jumpToLastPageTask = nil
        jumpToLastPageForChapterId = nil
        isFollowing = false
        pageDirection = .forward
        if currentPage + 1 < totalPages {
            if settings.pageTurnStyle == .slide {
                isPageTurning = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage += 1
                }
                pageTurnResetTask?.cancel()
                pageTurnResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    isPageTurning = false
                }
            } else {
                currentPage += 1
            }
        } else if onAdvanceChapter?() == true {
            // Caller swapped chapter; currentPage resets via onChange.
        }
    }

    private func retreatPage() {
        FlickerProbe.shared.log("retreatPage() CALLED chapter.id=\(chapter.id) currentPage=\(currentPage) isPageTurning=\(isPageTurning) debounceOk=\(Date().timeIntervalSince(lastPageTurnAt) > pageTurnDebounce)")
        guard !isPageTurning,
              Date().timeIntervalSince(lastPageTurnAt) > pageTurnDebounce else { return }
        lastPageTurnAt = Date()
        jumpToLastPageTask?.cancel()
        jumpToLastPageTask = nil
        jumpToLastPageForChapterId = nil
        isFollowing = false
        pageDirection = .backward
        if currentPage > 0 {
            if settings.pageTurnStyle == .slide {
                isPageTurning = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage -= 1
                }
                pageTurnResetTask?.cancel()
                pageTurnResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    isPageTurning = false
                }
            } else {
                currentPage -= 1
            }
        } else {
            jumpToLastPageForChapterId = "__pending__"
            FlickerProbe.shared.log("retreatPage CALLING onPreviousChapter chapter.id=\(chapter.id)")
            let callFailedOrNil = onPreviousChapter?() != true
            FlickerProbe.shared.log("retreatPage onPreviousChapter RETURNED handled=\(!callFailedOrNil) chapter.id=\(chapter.id)")
            if callFailedOrNil {
                jumpToLastPageForChapterId = nil
            }
        }
    }

    /// Locate which page contains the active sentence's text. Used by
    /// the auto-follow effect to keep the reader on the page the audio
    /// is currently narrating.
    private func pageIndexContaining(sentence: SentenceSpan, in pages: [NSAttributedString]) -> Int? {
        let needle = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        // Search by a prefix (first 40 chars) so we tolerate minor
        // whitespace / punctuation differences between
        // `SentenceSpan.text` and the rendered attributed string.
        let probe = String(needle.prefix(40))
        for (i, page) in pages.enumerated() {
            if (page.string as NSString).range(of: probe).location != NSNotFound {
                return i
            }
        }
        return nil
    }

    // (sliceWithSentenceHighlight removed — see comment in `pageView`.)

    // MARK: Header / sentence rows

    private var chapterTitleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chapter.displayTitle)
                .font(headingFont)
                .fontWeight(.semibold)
            if settings.readerLayout == .scrolling, let count = chapter.charCount {
                Text(L10n.string("reader.characters", count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func sentenceRow(_ span: SentenceSpan) -> some View {
        let isActive = (span.id == currentSentenceId)
        // Active-sentence cue: yellow background is the primary
        // signal. Under Differentiate Without Color we ADD a leading
        // accent border + bold weight so users with tritanopia /
        // settings that desaturate the UI still see which sentence
        // is being read. The accessibility label inside `sentenceText`
        // already names the text, but a sighted low-vision user
        // needs the visual cue too.
        sentenceText(span, isActive: isActive)
            .lineSpacing(settings.readerLineSpacing)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.yellow.opacity(0.35) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isActive && differentiateWithoutColor {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onJumpToSentence?(span) }
            .accessibilityHint(onJumpToSentence != nil ? L10n.string("reader.seekSentenceHint") : "")
    }

    @ViewBuilder
    private func sentenceText(_ span: SentenceSpan, isActive: Bool = false) -> some View {
        Text(span.text)
            .font(activeWeightedFont(isActive: isActive))
            .foregroundStyle(themeForeground)
    }

    /// Bold weight on the active sentence when Differentiate Without
    /// Color is on — adds a non-colour signal. Wrapped here because
    /// SwiftUI's `Text.fontWeight(_:)` is iOS 16+/macOS 13+; pre-13
    /// macOS rebuilds the Font with `.weight(_:)` instead.
    private func activeWeightedFont(isActive: Bool) -> Font {
        let base = bodyFont
        guard isActive && differentiateWithoutColor else { return base }
        return base.weight(.semibold)
    }

    // MARK: Typography

    private var bodyFont: Font {
        let size = settings.readerPointSize
        switch settings.readerFontFamily {
        case .serif: return .system(size: size, design: .serif)
        case .sans:  return .system(size: size, design: .default)
        case .mono:  return .system(size: size, design: .monospaced)
        }
    }

    private var headingFont: Font {
        let size = settings.readerPointSize + 6
        switch settings.readerFontFamily {
        case .serif: return .system(size: size, design: .serif)
        case .sans:  return .system(size: size, design: .default)
        case .mono:  return .system(size: size, design: .monospaced)
        }
    }

    // MARK: - Theme colours (delegated to ReaderTheme, WCAG ≥ 7:1)

    private var themeBackground: Color {
        settings.readerTheme.background(
            customBg: settings.readerTheme == .custom ? settings.readerCustomColors.background : nil
        )
    }

    private var themeForeground: Color {
        settings.readerTheme.foreground(
            customFg: settings.readerTheme == .custom ? settings.readerCustomColors.foreground : nil
        )
    }

    var themeAccent: Color { settings.readerTheme.accent }

}

/// PreferenceKey used to propagate the reader container's CGSize from a
/// background GeometryReader to the main body, so `effectiveReaderMargin`
/// can react to orientation changes in both scrolling and paginated modes.
private struct ContainerSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct ReaderColorSchemeModifier: ViewModifier {
    let theme: ReaderTheme
    func body(content: Content) -> some View {
        if let scheme = theme.preferredColorScheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("Reader — light scrolling") {
    ReaderView(
        chapter: EbookFulltext.previewSample.chapters[0],
        spans: EbookFulltext.previewSample.chapters[0].splitSentences(),
        currentSentenceId: "1:1",
        onJumpToSentence: { _ in }
    )
    .environmentObject(AppSettings())
}

#Preview("Reader — paginated parchment") {
    let settings = AppSettings()
    settings.readerTheme = .parchment
    settings.readerLayout = .paginated
    return ReaderView(
        chapter: EbookFulltext.previewSample.chapters[0],
        spans: EbookFulltext.previewSample.chapters[0].splitSentences(),
        currentSentenceId: nil,
        onJumpToSentence: { _ in }
    )
    .environmentObject(settings)
}

#Preview("Reader — dark large font") {
    let settings = AppSettings()
    settings.readerTheme = .dark
    settings.readerFontSize = 3
    return ReaderView(
        chapter: EbookFulltext.previewSample.chapters[1],
        spans: EbookFulltext.previewSample.chapters[1].splitSentences(),
        currentSentenceId: nil,
        onJumpToSentence: { _ in }
    )
    .environmentObject(settings)
}

#Preview("Reader — Dark (toolbar contrast check)") {
    let settings = AppSettings()
    settings.readerTheme = .dark
    return ReaderView(
        chapter: EbookFulltext.previewSample.chapters[0],
        spans: EbookFulltext.previewSample.chapters[0].splitSentences(),
        currentSentenceId: nil,
        onJumpToSentence: { _ in }
    )
    .environmentObject(settings)
    // Simulate OS in light mode to expose the problem that
    // .preferredColorScheme fixes.
    .environment(\.colorScheme, .light)
}

#Preview("Reader — Sepia (toolbar contrast check)") {
    let settings = AppSettings()
    settings.readerTheme = .sepia
    return ReaderView(
        chapter: EbookFulltext.previewSample.chapters[0],
        spans: EbookFulltext.previewSample.chapters[0].splitSentences(),
        currentSentenceId: nil,
        onJumpToSentence: { _ in }
    )
    .environmentObject(settings)
}


#Preview("Reader — Black (OLED)") {
    let settings = AppSettings()
    settings.readerTheme = .black
    settings.readerFontSize = 2
    return ReaderView(
        chapter: EbookFulltext.previewSample.chapters[0],
        spans: EbookFulltext.previewSample.chapters[0].splitSentences(),
        currentSentenceId: "1:1",
        onJumpToSentence: { _ in }
    )
    .environmentObject(settings)
}
#endif
