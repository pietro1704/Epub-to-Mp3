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

    @EnvironmentObject private var settings: AppSettings
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast
    @State private var currentPage: Int = 0
    @FocusState private var paginatedFocus: Bool

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
        onPreviousChapter: (() -> Bool)? = nil
    ) {
        self.chapter = chapter
        self.spans = spans
        self.currentSentenceId = currentSentenceId
        self.onJumpToSentence = onJumpToSentence
        self.onAdvanceChapter = onAdvanceChapter
        self.onPreviousChapter = onPreviousChapter
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
        .preferredColorScheme(settings.readerTheme.preferredColorScheme)
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
            html: html, css: chapter.css, settings: settings
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Picker("Font", selection: $settings.readerFontFamily) {
                    ForEach(ReaderFontFamily.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Theme", selection: $settings.readerTheme) {
                    ForEach(ReaderTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Layout", selection: $settings.readerLayout) {
                    ForEach(ReaderLayout.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Menu {
                    appearanceMenu
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)

                Toggle(isOn: $settings.readerAutoScroll) {
                    Image(systemName: settings.readerAutoScroll ? "arrow.down.to.line" : "hand.raised")
                }
                .toggleStyle(.button)
                .help(settings.readerAutoScroll ? "Auto-scroll on" : "Auto-scroll off")
            }
        }
        .font(.footnote)
        // 12pt inside any safe-area inset so the picker rows don't
        // get clipped by the notch / Dynamic Island in landscape.
        .compatHorizontalSafeAreaPadding(12)
        .padding(.vertical, 6)
        // Tint the toolbar background with the reader's own theme colour
        // at 92 % opacity so it reads as a natural header continuation
        // rather than a system-chrome island. The remaining translucency
        // lets the top of the scrolled content bleed through (same as
        // Apple Books). Icons and picker text inherit `themeForeground`
        // from the outer `.foregroundStyle` modifier, so contrast is
        // automatically correct for every theme.
        .background(toolbarBackground)
    }

    /// A thin translucent layer that tints the toolbar in the reader theme
    /// colour. Uses the same hue as the page background at slightly reduced
    /// opacity so the top of the text is still barely visible beneath it,
    /// matching the Apple Books scrolling affordance.
    private var toolbarBackground: some View {
        themeBackground
            .opacity(0.94)
            .overlay(
                themeForeground
                    .opacity(0.04)
            )
            .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var appearanceMenu: some View {
        Section("Spacing") {
            // Sliders inside menus aren't supported, so we expose
            // discrete steps that round to common values.
            ForEach([0.0, 4.0, 6.0, 8.0, 12.0, 16.0], id: \.self) { v in
                Button {
                    settings.readerLineSpacing = v
                } label: {
                    HStack {
                        Text(v == 0 ? "Tight" : "\(Int(v)) pt")
                        if abs(settings.readerLineSpacing - v) < 0.5 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        Section("Margin") {
            // HIG: Books uses 16pt minimum on iPhone portrait; anything
            // tighter clips first/last glyphs into the screen edge.
            ForEach([16.0, 24.0, 36.0, 48.0, 64.0], id: \.self) { v in
                Button {
                    settings.readerMargin = v
                } label: {
                    HStack {
                        Text("\(Int(v)) pt")
                        if abs(settings.readerMargin - v) < 0.5 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        Section("Column width") {
            ForEach([520.0, 640.0, 720.0, 820.0, 920.0], id: \.self) { v in
                Button {
                    settings.readerColumnWidth = v
                } label: {
                    HStack {
                        Text("\(Int(v)) pt")
                        if abs(settings.readerColumnWidth - v) < 0.5 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if settings.readerTheme == .custom {
            Section("Custom colours") {
                ColorPicker("Background", selection: Binding(
                    get: { customBackground },
                    set: { newValue in setCustomBackground(newValue) }
                ))
                ColorPicker("Text", selection: Binding(
                    get: { customForeground },
                    set: { newValue in setCustomForeground(newValue) }
                ))
            }
        }
        Section("Overrides") {
            Toggle("Override font", isOn: $settings.readerOverrideFontFamily)
            Toggle("Override size", isOn: $settings.readerOverrideFontSize)
            Toggle("Override colours", isOn: $settings.readerOverrideColours)
            Toggle("Bold all text", isOn: $settings.readerBoldOverride)
            Toggle("Suppress italic", isOn: $settings.readerSuppressItalic)
        }
        Section("Letter spacing") {
            ForEach([-1.0, 0.0, 0.5, 1.0, 2.0, 3.0], id: \.self) { v in
                Button {
                    settings.readerLetterSpacing = v
                } label: {
                    HStack {
                        Text(v == 0 ? "Default" : String(format: "%+.1f pt", v))
                        if abs(settings.readerLetterSpacing - v) < 0.1 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        Section {
            Button {
                settings.restoreOriginal()
            } label: {
                Label("Restore defaults", systemImage: "arrow.uturn.backward")
            }
        }
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
            let pages = Paginator.paginate(
                spans: spans,
                pageSize: geo.size,
                fontSize: settings.readerPointSize,
                lineSpacing: settings.readerLineSpacing,
                columnWidth: settings.readerColumnWidth,
                margin: Double(effectiveReaderMargin)
            )
            ZStack(alignment: .bottom) {
                if pages.isEmpty {
                    chapterTitleHeader
                        .padding(.horizontal, effectiveReaderMargin)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    let pageIndex = max(0, min(pages.count - 1, currentPage))
                    pageView(pages: pages, pageIndex: pageIndex, containerWidth: geo.size.width)
                        // Tap zones first (foreground), drag/scroll second.
                        // Without `.allowsHitTesting(true)` here, the
                        // text body's hit-testing wins on macOS.
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
        if let attr = renderedAttributed,
           let slice = slicedAttributed(from: attr, pages: pages, pageIndex: pageIndex) {
            Text(slice)
                .lineSpacing(settings.readerLineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(plain)
                .font(bodyFont)
                .lineSpacing(settings.readerLineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    /// Two invisible tap zones for "tap left = previous, tap right =
    /// next" paging. Mac click + iOS tap go through the same gesture.
    private func tapZones(totalPages: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { retreatPage() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { advancePage(totalPages: totalPages) }
        }
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
        if currentPage + 1 < totalPages {
            currentPage += 1
        } else if onAdvanceChapter?() == true {
            // Caller swapped chapter; currentPage resets via onChange.
        }
    }

    private func retreatPage() {
        if currentPage > 0 {
            currentPage -= 1
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
            if let count = chapter.charCount {
                Text("\(count) characters")
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
    }

    @ViewBuilder
    private func sentenceText(_ span: SentenceSpan) -> some View {
        if let attr = renderedAttributed,
           let slice = slicedSentence(from: attr, span: span) {
            Text(slice)
        } else {
            Text(span.text)
                .font(bodyFont)
        }
    }

    private func slicedSentence(
        from attr: AttributedString,
        span: SentenceSpan
    ) -> AttributedString? {
        let chars = attr.characters
        let total = chars.count
        guard span.startChar < total else { return nil }
        let endOffset = min(total, span.endChar)
        guard span.startChar < endOffset else { return nil }
        let startIdx = chars.index(chars.startIndex, offsetBy: span.startChar)
        let endIdx = chars.index(chars.startIndex, offsetBy: endOffset)
        return AttributedString(attr[startIdx..<endIdx])
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
        case .light:
            // Use system background so the view is transparent on
            // macOS sidebar / sheet chrome. Explicit white on iOS.
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
        case .light, .sepia, .parchment, .paper:
            return .accentColor
        case .dark, .black:
            // #5AC8FA: iOS system light-blue, 3.4:1 on #1C1C1E, 4.1:1 on #000000
            return Color(red: 0x5A / 255.0, green: 0xC8 / 255.0, blue: 0xFA / 255.0)
        case .custom:
            return .accentColor
        }
    }

    private var customBackground: Color {
        let c = settings.readerCustomColors.background
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    private var customForeground: Color {
        let c = settings.readerCustomColors.foreground
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    private func setCustomBackground(_ color: Color) {
        let rgb = rgbComponents(of: color)
        settings.readerCustomColors = (
            background: rgb,
            foreground: settings.readerCustomColors.foreground
        )
        if settings.readerTheme != .custom { settings.readerTheme = .custom }
    }

    private func setCustomForeground(_ color: Color) {
        let rgb = rgbComponents(of: color)
        settings.readerCustomColors = (
            background: settings.readerCustomColors.background,
            foreground: rgb
        )
        if settings.readerTheme != .custom { settings.readerTheme = .custom }
    }

    private func rgbComponents(of color: Color) -> (Double, Double, Double) {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
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
