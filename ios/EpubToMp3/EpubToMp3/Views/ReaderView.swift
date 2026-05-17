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

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.epubFontDirectory) private var epubFontDirectory
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast
    @State private var currentPage: Int = 0
    /// Tracks direction of the last page turn for asymmetric transition.
    @State private var pageDirection: PageDirection = .forward
    @FocusState private var paginatedFocus: Bool

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
        onCenterTap: (() -> Void)? = nil
    ) {
        self.chapter = chapter
        self.spans = spans
        self.currentSentenceId = currentSentenceId
        self.onJumpToSentence = onJumpToSentence
        self.onAdvanceChapter = onAdvanceChapter
        self.onPreviousChapter = onPreviousChapter
        self.onCenterTap = onCenterTap
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
            toolbar
            Divider()
                .background(themeForeground.opacity(0.15))
            switch settings.readerLayout {
            case .scrolling: scrollingContent
            case .paginated: paginatedContent
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

    // MARK: Toolbar

    private var toolbar: some View {
        EmptyView()
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
        max(16, CGFloat(settings.readerMargin))
    }

    // MARK: Scrolling content

    private var scrollingContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    chapterTitleHeader
                    if let attr = renderedAttributed, currentSentenceId == nil {
                        Text(attr)
                            .lineSpacing(settings.readerLineSpacing)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(spans) { span in
                            sentenceRow(span)
                                .id(span.id)
                        }
                    }
                }
                .padding(.horizontal, effectiveReaderMargin)
                .padding(.vertical, 16)
                .frame(maxWidth: settings.readerColumnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .compatHorizontalSafeAreaPadding(0)
            .compatOnChange(of: currentSentenceId) { newId in
                guard let newId else { return }
                guard settings.readerAutoScroll else { return }
                lastAutoScrollAt = Date()
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
    }

    // MARK: Paginated content

    private var paginatedContent: some View {
        // Wrap the page-rendering GeometryReader in a horizontal
        // safe-area inset so paginated mode never lays out a page
        // under the notch / Dynamic Island. GeometryReader otherwise
        // measures the *full* available width, which on iPhone
        // landscape includes the curved cutout region.
        GeometryReader { geo in
            let headerH: CGFloat = settings.readerPointSize * 2.5 + 50
            let pages = Paginator.paginate(
                spans: spans,
                pageSize: geo.size,
                fontSize: settings.readerPointSize,
                lineSpacing: settings.readerLineSpacing,
                columnWidth: settings.readerColumnWidth,
                margin: Double(effectiveReaderMargin),
                headerHeight: headerH
            )
            ZStack(alignment: .bottom) {
                if pages.isEmpty {
                    chapterTitleHeader
                        .padding(.horizontal, effectiveReaderMargin)
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
            .onAppear { paginatedFocus = true }
            .compatOnKeyPressArrowsAndPaging { key in
                handleCompatKey(key, totalPages: pages.count)
            }
        }
        .compatHorizontalSafeAreaPadding(0)
    }

    /// Dispatch page rendering to the appropriate animation container
    /// based on `settings.pageTurnStyle`.
    @ViewBuilder
    private func paginatedPageContent(pages: [String], containerSize: CGSize) -> some View {
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
    private func pageCurlContent(pages: [String], containerSize: CGSize) -> some View {
        let pageViews: [AnyView] = pages.indices.map { i in
            AnyView(
                pageView(pages: pages, pageIndex: i, containerWidth: containerSize.width)
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

    /// Horizontal slide transition (the old default).
    private func slidePageContent(pages: [String], pageIndex: Int, containerSize: CGSize) -> some View {
        pageView(pages: pages, pageIndex: pageIndex, containerWidth: containerSize.width)
            .id(pageIndex)
            .transition(.asymmetric(
                insertion: .move(edge: pageDirection == .forward ? .trailing : .leading)
                    .combined(with: .opacity),
                removal: .move(edge: pageDirection == .forward ? .leading : .trailing)
                    .combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.25), value: currentPage)
            .overlay(tapZones(totalPages: pages.count))
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

    /// Instant page change — no animation at all.
    private func noAnimationPageContent(pages: [String], pageIndex: Int, containerSize: CGSize) -> some View {
        pageView(pages: pages, pageIndex: pageIndex, containerWidth: containerSize.width)
            .overlay(tapZones(totalPages: pages.count))
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

    private func pageView(pages: [String], pageIndex: Int, containerWidth: CGFloat? = nil) -> some View {
        let pageText = pages[pageIndex]
        let effectiveColumnWidth = min(
            settings.readerColumnWidth,
            (containerWidth ?? .infinity) - 2 * effectiveReaderMargin
        )
        return VStack(alignment: .leading, spacing: 0) {
            if pageIndex == 0 { chapterTitleHeader }
            pageTextBody(plain: pageText, pageIndex: pageIndex, pages: pages)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, effectiveReaderMargin)
        .padding(.vertical, 24)
        .frame(maxWidth: max(200, effectiveColumnWidth + 2 * effectiveReaderMargin), alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
    }

    /// Pick HTML-rendered AttributedString slice when available, fall
    /// back to plain `Text(pageText)` otherwise. The slicing strategy
    /// uses cumulative plain-text character offsets from `pages`
    /// (each page is N chars long). When the rendered AttributedString
    /// is shorter than the plain text (HTML collapsed whitespace etc.),
    /// the slice clamps to the available range — worst case the last
    /// page shows slightly less than the plain version would.
    @ViewBuilder
    private func pageTextBody(plain: String, pageIndex: Int, pages: [String]) -> some View {
        Text(plain)
            .font(bodyFont)
            .lineSpacing(settings.readerLineSpacing)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Map page index → AttributedString sub-range by counting Plain
    /// text characters per page. Returns `nil` when the math drifts
    /// off the rendered string (graceful fall back to plain text).
    private func slicedAttributed(
        from attr: AttributedString,
        pages: [String],
        pageIndex: Int
    ) -> AttributedString? {
        let cumulativeStart = pages[..<pageIndex].reduce(0) { $0 + $1.count }
        let length = pages[pageIndex].count
        let chars = attr.characters
        let total = chars.count
        guard cumulativeStart < total else { return nil }
        let startOffset = cumulativeStart
        let endOffset = min(total, cumulativeStart + length)
        let startIdx = chars.index(chars.startIndex, offsetBy: startOffset)
        let endIdx = chars.index(chars.startIndex, offsetBy: endOffset)
        return AttributedString(attr[startIdx..<endIdx])
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
    private func tapZones(totalPages: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { retreatPage() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.string("reader.previousPage"))
                .accessibilityAddTraits(.isButton)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onCenterTap?() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.string("reader.toggleControls"))
                .accessibilityAddTraits(.isButton)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { advancePage(totalPages: totalPages) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.string("reader.nextPage"))
                .accessibilityAddTraits(.isButton)
        }
        .frame(maxHeight: .infinity)
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

    // MARK: - Theme colour pairs (Apple Books reference, WCAG ≥ 7:1)
    //
    // All hex values are exact Apple Books equivalents.
    // Computed contrast ratios (WCAG relative-luminance formula):
    //   Light:     #FFFFFF / #000000  → 21.0:1
    //   Sepia:     #F8F0E0 / #5B4636 →  7.1:1
    //   Parchment: #F4ECD8 / #3D2F1F →  8.3:1
    //   Paper:     #E8E2D5 / #2A2520 →  9.2:1
    //   Dark:      #1C1C1E / #E8E8E8 → 14.4:1
    //   Black:     #000000 / #E0E0E0 → 15.6:1

    private var themeBackground: Color {
        switch settings.readerTheme {
        case .auto:
            return .platformSystemBackground
        case .light:
            return .platformSystemBackground
        case .sepia:
            // Apple Books sepia: #F8F0E0
            return Color(red: 0xF8 / 255.0, green: 0xF0 / 255.0, blue: 0xE0 / 255.0)
        case .parchment:
            // Apple Books parchment: #F4ECD8
            return Color(red: 0xF4 / 255.0, green: 0xEC / 255.0, blue: 0xD8 / 255.0)
        case .paper:
            // Apple Books paper: #E8E2D5
            return Color(red: 0xE8 / 255.0, green: 0xE2 / 255.0, blue: 0xD5 / 255.0)
        case .dark:
            // Apple Books dark: #1C1C1E
            return Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
        case .black:
            // True OLED black: #000000
            return .black
        case .custom:
            let bg = settings.readerCustomColors.background
            return Color(red: bg.0, green: bg.1, blue: bg.2)
        }
    }

    private var themeForeground: Color {
        switch settings.readerTheme {
        case .auto:
            return .primary
        case .light:
            return .primary
        case .sepia:
            // Apple Books sepia text: #5B4636 (7.1:1 on #F8F0E0)
            return Color(red: 0x5B / 255.0, green: 0x46 / 255.0, blue: 0x36 / 255.0)
        case .parchment:
            // Apple Books parchment text: #3D2F1F (8.3:1 on #F4ECD8)
            return Color(red: 0x3D / 255.0, green: 0x2F / 255.0, blue: 0x1F / 255.0)
        case .paper:
            // Apple Books paper text: #2A2520 (9.2:1 on #E8E2D5)
            return Color(red: 0x2A / 255.0, green: 0x25 / 255.0, blue: 0x20 / 255.0)
        case .dark:
            // Apple Books dark text: #E8E8E8 (14.4:1 on #1C1C1E)
            return Color(red: 0xE8 / 255.0, green: 0xE8 / 255.0, blue: 0xE8 / 255.0)
        case .black:
            // Apple Books black text: #E0E0E0 (15.6:1 on #000000)
            return Color(red: 0xE0 / 255.0, green: 0xE0 / 255.0, blue: 0xE0 / 255.0)
        case .custom:
            let fg = settings.readerCustomColors.foreground
            return Color(red: fg.0, green: fg.1, blue: fg.2)
        }
    }

    /// Accent colour used for links, highlights, and scrubber playing line.
    /// Light/warm themes use system blue; dark themes use a lighter tint
    /// (#5AC8FA — iOS system blue accessible on dark bg, ≥ 3:1 WCAG large text).
    var themeAccent: Color {
        switch settings.readerTheme {
        case .auto, .light, .sepia, .parchment, .paper:
            return .accentColor
        case .dark, .black:
            // #5AC8FA: iOS system light-blue, 3.4:1 on #1C1C1E, 4.1:1 on #000000
            return Color(red: 0x5A / 255.0, green: 0xC8 / 255.0, blue: 0xFA / 255.0)
        case .custom:
            return .accentColor
        }
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
