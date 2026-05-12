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
            switch settings.readerLayout {
            case .scrolling: scrollingContent
            case .paginated: paginatedContent
            }
        }
        .background(themeBackground)
        .foregroundStyle(themeForeground)
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
        HStack(spacing: 16) {
            // Font size A− / A+
            HStack(spacing: 4) {
                Button {
                    settings.readerFontSize = max(0, settings.readerFontSize - 1)
                } label: { Image(systemName: "textformat.size.smaller") }
                .disabled(settings.readerFontSize == 0)
                Text("\(settings.readerFontSize + 1)/5")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    settings.readerFontSize = min(4, settings.readerFontSize + 1)
                } label: { Image(systemName: "textformat.size.larger") }
                .disabled(settings.readerFontSize == 4)
            }

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

            Spacer()
        }
        .font(.footnote)
        // 12pt inside any safe-area inset so the picker rows don't
        // get clipped by the notch / Dynamic Island in landscape.
        .compatHorizontalSafeAreaPadding(12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
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
            ForEach([12.0, 24.0, 36.0, 48.0, 64.0], id: \.self) { v in
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

    // MARK: Scrolling content

    private var scrollingContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    chapterTitleHeader
                    ForEach(spans) { span in
                        sentenceRow(span)
                            .id(span.id)
                    }
                }
                .padding(.horizontal, settings.readerMargin)
                .padding(.vertical, 16)
                .frame(maxWidth: settings.readerColumnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Keep sentence rows clear of the notch / Dynamic Island
            // in iPhone landscape — even when the user dials the
            // reader margin down to 12pt, the system safe-area inset
            // still pushes content past the curved cutout.
            .compatHorizontalSafeAreaPadding(0)
            // No simultaneousGesture here — that previously stole
            // touches on iOS and competed with the system scroll
            // recogniser, making the reader feel "stuck". The
            // userIsScrolling lockout is still useful but we drive
            // it from `onScrollGeometryChange`-style hints in iOS 18+.
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
                margin: settings.readerMargin
            )
            ZStack(alignment: .bottom) {
                if pages.isEmpty {
                    chapterTitleHeader
                        .padding(.horizontal, settings.readerMargin)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    let pageIndex = max(0, min(pages.count - 1, currentPage))
                    pageView(pages: pages, pageIndex: pageIndex)
                        // Tap zones first (foreground), drag/scroll second.
                        // Without `.allowsHitTesting(true)` here, the
                        // text body's hit-testing wins on macOS.
                        .overlay(tapZones(totalPages: pages.count))
                        #if os(iOS)
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
                        #endif

                    pageFooter(index: pageIndex, total: pages.count)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
            .compatFocusable()
            .focused($paginatedFocus)
            .onAppear { paginatedFocus = true }
            .compatOnKeyPressArrowsAndPaging { key in
                handleCompatKey(key, totalPages: pages.count)
            }
            #if os(macOS)
            .modifier(ScrollWheelPager(
                onPrev: { retreatPage() },
                onNext: { advancePage(totalPages: pages.count) }
            ))
            #endif
        }
        .compatHorizontalSafeAreaPadding(0)
    }

    private func pageView(pages: [String], pageIndex: Int) -> some View {
        // No ScrollView here — paginated mode means the page must
        // fit. A nested ScrollView would (a) eat scroll-wheel events
        // we want for paging and (b) intercept clicks before our
        // tap-zone overlay.
        let pageText = pages[pageIndex]
        return VStack(alignment: .leading, spacing: 0) {
            if pageIndex == 0 { chapterTitleHeader }
            pageTextBody(plain: pageText, pageIndex: pageIndex, pages: pages)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, settings.readerMargin)
        .padding(.vertical, 24)
        .frame(maxWidth: settings.readerColumnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .font(bodyFont)
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
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
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
        Text(span.text)
            .font(bodyFont)
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

    // MARK: Theme

    private var themeBackground: Color {
        switch settings.readerTheme {
        case .light:     return .platformSystemBackground
        case .sepia:     return Color(red: 0.96, green: 0.93, blue: 0.85)
        case .parchment: return Color(red: 0.94, green: 0.89, blue: 0.78)
        case .paper:     return Color(red: 0.98, green: 0.97, blue: 0.94)
        case .dark:      return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .black:     return .black
        case .custom:
            let bg = settings.readerCustomColors.background
            return Color(red: bg.0, green: bg.1, blue: bg.2)
        }
    }

    private var themeForeground: Color {
        switch settings.readerTheme {
        case .light:     return .primary
        case .sepia:     return Color(red: 0.20, green: 0.15, blue: 0.10)
        case .parchment: return Color(red: 0.18, green: 0.13, blue: 0.06)
        case .paper:     return Color(red: 0.10, green: 0.10, blue: 0.10)
        case .dark:      return Color(white: 0.92)
        case .black:     return Color(white: 0.95)
        case .custom:
            let fg = settings.readerCustomColors.foreground
            return Color(red: fg.0, green: fg.1, blue: fg.2)
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
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #elseif canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        #else
        return (1, 1, 1)
        #endif
    }
}

#if os(macOS)
import AppKit

/// Wraps an NSView that captures scroll-wheel events so vertical
/// scroll gestures advance/back the paginated reader. Without this
/// SwiftUI's built-in gestures only respond to drag, not wheel.
struct ScrollWheelPager: ViewModifier {
    let onPrev: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        content.background(ScrollWheelView(onPrev: onPrev, onNext: onNext))
    }

    private struct ScrollWheelView: NSViewRepresentable {
        let onPrev: () -> Void
        let onNext: () -> Void

        func makeNSView(context: Context) -> NSView { ScrollWheelNSView(onPrev: onPrev, onNext: onNext) }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class ScrollWheelNSView: NSView {
        let onPrev: () -> Void
        let onNext: () -> Void
        private var lastFire: Date = .distantPast

        init(onPrev: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onPrev = onPrev
            self.onNext = onNext
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func scrollWheel(with event: NSEvent) {
            // Throttle so a single trackpad swipe doesn't blast through pages.
            guard Date().timeIntervalSince(lastFire) > 0.18 else { return }
            let dy = event.scrollingDeltaY
            if dy < -3 { onNext(); lastFire = Date() }
            else if dy > 3 { onPrev(); lastFire = Date() }
        }
    }
}
#endif

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
#endif
