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

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.epubFontDirectory) private var epubFontDirectory
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast
    @State private var currentPage: Int = 0
    /// Tracks direction of the last page turn for asymmetric transition.
    @State private var pageDirection: PageDirection = .forward
    @FocusState private var paginatedFocus: Bool
    /// Last known container size — used to detect orientation changes
    /// and recompute the page index so the reader stays on the same
    /// text passage after rotation.
    @State private var lastContainerSize: CGSize = .zero
    /// Cumulative plain-text character offset at the top of the page
    /// the user was reading before a repagination. Used to find the
    /// equivalent page in the new pagination.
    @State private var textOffsetAtCurrentPage: Int = 0

    /// Body area used for pagination, captured when chrome was visible.
    /// Toggling chrome shrinks/grows `GeometryReader`'s size because
    /// `safeAreaInset` / `.toolbar(_:for:)` are layout-altering — using
    /// that live value to repaginate caused the visible text to
    /// re-flow every time the tab bar / customTopBar / mini player
    /// appeared or disappeared. Locking to the chrome-visible size
    /// keeps pagination stable across chrome toggles.
    @State private var stableBodyHeight: CGFloat = 0

    // Debounced settings — updated 200ms after sliders stop moving.
    @State private var debouncedFontSize: CGFloat = 0
    @State private var debouncedLineSpacing: Double = 0
    @State private var debouncedMargin: Double = 0
    @State private var debouncedColumnWidth: Double = 0

    private enum PageDirection { case forward, backward }

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
        onLinkTap: ((URL) -> Bool)? = nil
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
        return VStack(spacing: 0) {
            // No inline toolbar: the host (InstantReaderView /
            // PlayerReaderView) already exposes search in its nav-bar
            // ToolbarItem, so a second magnifier here was redundant and
            // ate vertical reading area.
            switch settings.readerLayout {
            case .scrolling: scrollingContent
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
        .compatOnChange(of: chapter.id) { _ in currentPage = 0 }
        .task(id: renderedAttributedKey) {
            renderedAttributed = renderHtmlForChapter()
        }
        .onAppear {
            debouncedFontSize = settings.readerPointSize
            debouncedLineSpacing = settings.readerLineSpacing
            debouncedMargin = settings.readerMargin
            debouncedColumnWidth = settings.readerColumnWidth
        }
        .compatOnChange(of: settings.readerFontSize) { _ in
            let v = settings.readerPointSize
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                debouncedFontSize = v
            }
        }
        .compatOnChange(of: settings.readerLineSpacing) { new in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                debouncedLineSpacing = new
            }
        }
        .compatOnChange(of: settings.readerMargin) { new in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                debouncedMargin = new
            }
        }
        .compatOnChange(of: settings.readerColumnWidth) { new in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                debouncedColumnWidth = new
            }
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

    private var scrollingContent: some View {
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
                chapterTitleHeader
                    .padding(.horizontal, margin)
                    .padding(.top, 16)
                AttributedPageView(
                    attributed: scrollingAttributedString(
                        fontSize: effectiveFontSize,
                        lineSpacing: effectiveLineSpacing
                    ),
                    width: effectiveColumnWidth,
                    scrollable: true,
                    onLinkTap: onLinkTap
                )
                .padding(.horizontal, margin)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            // Scroll mode: tap anywhere on the reading surface toggles
            // chrome (Apple Books pattern — there's no left/right/center
            // tap-zone partition like paginated mode, so the whole
            // surface is the toggle). Uses `simultaneousGesture` so it
            // doesn't swallow the UITextView's own scroll gesture.
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { onCenterTap?() }
            )
        }
        .compatHorizontalSafeAreaPadding(0)
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

    // MARK: Paginated content

    private var paginatedContent: some View {
        // Wrap the page-rendering GeometryReader in a horizontal
        // safe-area inset so paginated mode never lays out a page
        // under the notch / Dynamic Island. GeometryReader otherwise
        // measures the *full* available width, which on iPhone
        // landscape includes the curved cutout region.
        GeometryReader { geo in
            let margin = effectiveReaderMargin(for: geo.size)
            let effectiveFontSize: CGFloat = debouncedFontSize > 0 ? debouncedFontSize : settings.readerPointSize
            let effectiveLineSpacing: Double = debouncedLineSpacing > 0 ? debouncedLineSpacing : settings.readerLineSpacing
            let effectiveColumnWidth: CGFloat = debouncedColumnWidth > 0 ? CGFloat(debouncedColumnWidth) : settings.readerColumnWidth
            // No `headerHeight` now — chapterTitleHeader was dropped
            // (the EPUB's own heading flows as the first paragraph of
            // page 0). All pages share the same body budget:
            //   geo.size.height - 24 top - 24 bottom - 28 footer.
            let liveBodyHeight = max(120, geo.size.height - 76)
            let usedBodyHeight = chromeVisible || stableBodyHeight == 0
                ? liveBodyHeight
                : stableBodyHeight
            let pageBodySize = CGSize(width: geo.size.width, height: usedBodyHeight)
            let pages = attributedPages(
                pageSize: pageBodySize,
                margin: margin,
                columnWidth: effectiveColumnWidth,
                headerHeight: 0,
                fontSize: effectiveFontSize,
                lineSpacing: effectiveLineSpacing
            )
            ZStack(alignment: .bottom) {
                if pages.isEmpty {
                    chapterTitleHeader
                        .padding(.horizontal, margin)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    paginatedPageContent(pages: pages, containerSize: geo.size)

                    let pageIndex = max(0, min(pages.count - 1, currentPage))
                    pageFooter(index: pageIndex, total: pages.count)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
            .compatFocusable()
            .focused($paginatedFocus)
            .modifier(HideFocusRingModifier())
            .onAppear {
                paginatedFocus = true
                lastContainerSize = geo.size
                // Seed the stable body size on first mount so the very
                // first pagination uses chrome-visible dimensions.
                if stableBodyHeight == 0 {
                    stableBodyHeight = liveBodyHeight
                }
            }
            .compatOnKeyPressArrowsAndPaging { key in
                handleCompatKey(key, totalPages: pages.count)
            }
            .compatOnChange(of: geo.size) { newSize in
                // Track the chrome-visible body size so pagination stays
                // pinned to the smaller, "all chrome on" layout. When
                // chrome is hidden the live size *grows* and we ignore
                // it; when chrome comes back the live size matches the
                // stable value and we re-confirm. Real layout changes
                // (rotation / iPad resize) update stableBodyHeight when
                // chromeVisible == true so subsequent paginations track
                // the new orientation.
                if chromeVisible {
                    stableBodyHeight = max(120, newSize.height - 76)
                }
                guard sizeChangedMeaningfully(from: lastContainerSize, to: newSize) else { return }
                lastContainerSize = newSize
                if !pages.isEmpty {
                    let target = findPage(containing: textOffsetAtCurrentPage, in: pages)
                    if target != currentPage {
                        currentPage = target
                    }
                }
            }
            // Keep textOffsetAtCurrentPage in sync whenever the page changes.
            .compatOnChange(of: currentPage) { newPage in
                textOffsetAtCurrentPage = cumulativeOffset(page: newPage, in: pages)
            }
        }
        .compatHorizontalSafeAreaPadding(0)
    }

    /// True when the size delta is large enough to warrant repagination.
    /// Filters out sub-point jitter from keyboard, status bar, etc.
    private func sizeChangedMeaningfully(from old: CGSize, to new: CGSize) -> Bool {
        abs(old.width - new.width) > 2 || abs(old.height - new.height) > 2
    }

    /// Cumulative plain-text character count up to (but not including) the
    /// given page index. Used to bookmark the reading position.
    private func cumulativeOffset(page: Int, in pages: [NSAttributedString]) -> Int {
        guard !pages.isEmpty else { return 0 }
        let clamped = max(0, min(pages.count - 1, page))
        return pages[..<clamped].reduce(0) { $0 + $1.length }
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
        let base: NSAttributedString
        if let rendered = renderedAttributed {
            base = NSAttributedString(rendered)
        } else {
            let plain = spans.map(\.text).joined(separator: "\n\n")
            let font = bodyPlatformFont(size: fontSize)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = CGFloat(lineSpacing)
            base = NSAttributedString(string: plain, attributes: [
                .font: font,
                .paragraphStyle: para,
            ])
        }
        return Paginator.paginateAttributed(
            base,
            pageSize: pageSize,
            columnWidth: columnWidth,
            margin: Double(margin),
            headerHeight: headerHeight
        )
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
    private func paginatedPageContent(pages: [NSAttributedString], containerSize: CGSize) -> some View {
        let pageIndex = max(0, min(pages.count - 1, currentPage))
        switch settings.pageTurnStyle {
        #if os(iOS)
        case .flip:
            pageCurlContent(pages: pages, containerSize: containerSize)
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
    /// Apple Books-style page curl using UIPageViewController.
    private func pageCurlContent(pages: [NSAttributedString], containerSize: CGSize) -> some View {
        let pageViews: [AnyView] = pages.indices.map { i in
            AnyView(
                pageView(pages: pages, pageIndex: i, containerSize: containerSize)
                    .background(themeBackground)
            )
        }
        return PageCurlContainer(
            pages: pageViews,
            currentPage: $currentPage,
            onAdvanceChapter: onAdvanceChapter,
            onPreviousChapter: onPreviousChapter,
            onCenterTap: onCenterTap
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
        let totalPages = pages.count
        let margin = effectiveReaderMargin(for: containerSize)
        let columnW = min(settings.readerColumnWidth, containerSize.width - 2 * margin)
        // textOriginY = top padding only — chapterTitleHeader was dropped
        // (EPUB's own heading is the first content of page 0 now).
        let textOriginY: CGFloat = 24
        let linkHits = pageLinkHits(pages: pages, pageIndex: pageIndex, columnWidth: columnW)
        return pageView(pages: pages, pageIndex: pageIndex, containerSize: containerSize)
            .overlay(tapZones(
                totalPages: totalPages,
                linkHits: linkHits,
                textOriginX: margin,
                textOriginY: textOriginY
            ))
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            advancePage(totalPages: pages.count)
                        } else if value.translation.width > 40 {
                            retreatPage()
                        }
                    }
            )
    }

    private func noAnimationPageContent(pages: [NSAttributedString], pageIndex: Int, containerSize: CGSize) -> some View {
        let totalPages = pages.count
        let margin = effectiveReaderMargin(for: containerSize)
        let columnW = min(settings.readerColumnWidth, containerSize.width - 2 * margin)
        let textOriginY: CGFloat = 24
        let linkHits = pageLinkHits(pages: pages, pageIndex: pageIndex, columnWidth: columnW)
        return pageView(pages: pages, pageIndex: pageIndex, containerSize: containerSize)
            .overlay(tapZones(
                totalPages: totalPages,
                linkHits: linkHits,
                textOriginX: margin,
                textOriginY: textOriginY
            ))
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            advancePage(totalPages: pages.count)
                        } else if value.translation.width > 40 {
                            retreatPage()
                        }
                    }
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
        switch zone {
        case .left:   retreatPage()
        case .center: onCenterTap?()
        case .right:  advancePage(totalPages: totalPages)
        }
    }

    private func handleSwipe(_ direction: ReaderSwipeDirection, totalPages: Int) {
        switch direction {
        case .left:  advancePage(totalPages: totalPages)
        case .right: retreatPage()
        }
    }

    private func pageView(pages: [NSAttributedString], pageIndex: Int, containerSize: CGSize) -> some View {
        let margin = effectiveReaderMargin(for: containerSize)
        let attributedSlice = pages[pageIndex]
        let effectiveColumnWidth = min(
            settings.readerColumnWidth,
            containerSize.width - 2 * margin
        )
        // No more separate `chapterTitleHeader` on page 0: the rendered
        // EPUB attributed string already begins with the chapter's own
        // `<h1>` / `<h2>` heading (from EpubHtmlRenderer). Drawing our
        // own big serif title above that produced a visible duplicate
        // AND ate ~80pt that the Paginator then had to reserve via
        // `headerHeight`, leaving the body area underfilled by a couple
        // of lines. Letting the EPUB heading flow inline as page-0
        // content means the body area is the same on every page and
        // Paginator fills it precisely.
        return VStack(alignment: .leading, spacing: 0) {
            pageTextBody(attributedSlice, width: effectiveColumnWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, margin)
        .padding(.vertical, 24)
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
    @ViewBuilder
    private func pageTextBody(_ slice: NSAttributedString, width: CGFloat) -> some View {
        AttributedPageView(
            attributed: slice,
            width: width,
            onLinkTap: onLinkTap
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
    }

    /// Three invisible tap zones for page turning (Apple Books style):
    /// left 33% = previous page, center 33% = toggle chrome, right 33% = next page.
    /// Each handler first checks whether the tap landed on a `.link`
    /// glyph (using the precomputed `linkHits` from TextKit); if it
    /// did, the link takes precedence and the zone's default action is
    /// skipped. iOS 16+ uses `SpatialTapGesture` for the tap location;
    /// iOS 15 falls back to the zone-only behaviour.
    @ViewBuilder
    private func tapZones(
        totalPages: Int,
        linkHits: [(url: URL, rect: CGRect)],
        textOriginX: CGFloat,
        textOriginY: CGFloat
    ) -> some View {
        if #available(iOS 16, macOS 13, *) {
            HStack(spacing: 0) {
                tapZone(linkHits: linkHits, originX: textOriginX, originY: textOriginY) {
                    retreatPage()
                }
                .accessibilityLabel(L10n.string("reader.previousPage"))
                tapZone(linkHits: linkHits, originX: textOriginX, originY: textOriginY) {
                    onCenterTap?()
                }
                .accessibilityLabel(L10n.string("reader.toggleControls"))
                tapZone(linkHits: linkHits, originX: textOriginX, originY: textOriginY) {
                    advancePage(totalPages: totalPages)
                }
                .accessibilityLabel(L10n.string("reader.nextPage"))
            }
            .frame(maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { retreatPage() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { onCenterTap?() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { advancePage(totalPages: totalPages) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// One third of the page-area tap surface. iOS 16+
    /// `SpatialTapGesture` reports the tap location (relative to the
    /// `.named("readerPage")` coordinate space that wraps the page),
    /// which the handler offsets into text-content space and queries
    /// against `linkHits`. Link tap wins; otherwise the fallback
    /// zone action fires.
    @available(iOS 16, macOS 13, *)
    @ViewBuilder
    private func tapZone(
        linkHits: [(url: URL, rect: CGRect)],
        originX: CGFloat,
        originY: CGFloat,
        fallback: @escaping () -> Void
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("readerPage"))
                    .onEnded { value in
                        let pagePoint = value.location
                        let textPoint = CGPoint(
                            x: pagePoint.x - originX,
                            y: pagePoint.y - originY
                        )
                        if let url = linkHits.first(where: { $0.rect.contains(textPoint) })?.url {
                            if onLinkTap?(url) == true { return }
                        }
                        fallback()
                    }
            )
            .accessibilityAddTraits(.isButton)
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
        // Per user spec: page turn never toggles chrome. The chrome
        // state (visible/hidden) is preserved across page turns —
        // only an explicit center-tap toggles it.
        pageDirection = .forward
        if currentPage + 1 < totalPages {
            if settings.pageTurnStyle == .slide {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage += 1
                }
            } else {
                currentPage += 1
            }
        } else if onAdvanceChapter?() == true {
            // Caller swapped chapter; currentPage resets via onChange.
        }
    }

    private func retreatPage() {
        pageDirection = .backward
        if currentPage > 0 {
            if settings.pageTurnStyle == .slide {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentPage -= 1
                }
            } else {
                currentPage -= 1
            }
        } else if onPreviousChapter?() == true {
            // Caller swapped chapter; currentPage resets via onChange.
        }
    }

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
        sentenceText(span)
            .lineSpacing(settings.readerLineSpacing)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.yellow.opacity(0.35) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { onJumpToSentence?(span) }
            .accessibilityHint(onJumpToSentence != nil ? "Double tap to seek audio to this sentence" : "")
    }

    @ViewBuilder
    private func sentenceText(_ span: SentenceSpan) -> some View {
        Text(span.text)
            .font(bodyFont)
            .foregroundStyle(themeForeground)
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
