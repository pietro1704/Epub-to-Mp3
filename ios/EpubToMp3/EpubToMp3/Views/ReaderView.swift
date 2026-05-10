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

    @Environment(AppSettings.self) private var settings
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast
    @State private var currentPage: Int = 0
    @FocusState private var paginatedFocus: Bool

    init(
        chapter: EbookFulltext.Chapter,
        spans: [SentenceSpan],
        currentSentenceId: String?,
        onJumpToSentence: ((SentenceSpan) -> Void)? = nil
    ) {
        self.chapter = chapter
        self.spans = spans
        self.currentSentenceId = currentSentenceId
        self.onJumpToSentence = onJumpToSentence
    }

    var body: some View {
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
        .onChange(of: chapter.id) { _, _ in currentPage = 0 }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        @Bindable var bindable = settings
        return HStack(spacing: 16) {
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

            Picker("Font", selection: $bindable.readerFontFamily) {
                ForEach(ReaderFontFamily.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker("Theme", selection: $bindable.readerTheme) {
                ForEach(ReaderTheme.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker("Layout", selection: $bindable.readerLayout) {
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

            Toggle(isOn: $bindable.readerAutoScroll) {
                Image(systemName: settings.readerAutoScroll ? "arrow.down.to.line" : "hand.raised")
            }
            .toggleStyle(.button)
            .help(settings.readerAutoScroll ? "Auto-scroll on" : "Auto-scroll off")

            Spacer()
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var appearanceMenu: some View {
        @Bindable var bindable = settings
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in userIsScrolling = true }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            userIsScrolling = false
                        }
                    }
            )
            .onChange(of: currentSentenceId) { _, newId in
                guard let newId else { return }
                guard settings.readerAutoScroll, !userIsScrolling else { return }
                lastAutoScrollAt = Date()
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
    }

    // MARK: Paginated content

    private var paginatedContent: some View {
        // Chunk the chapter into pages by character count, sized to
        // roughly fit the column width × screen height. This is a
        // fast approximation; SwiftUI doesn't ship a TextKit-backed
        // paginator for arbitrary fonts. Good enough for novels.
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
                        #if os(iOS)
                        .gesture(
                            DragGesture(minimumDistance: 30)
                                .onEnded { value in
                                    if value.translation.width < -40, currentPage + 1 < pages.count {
                                        currentPage += 1
                                    } else if value.translation.width > 40, currentPage > 0 {
                                        currentPage -= 1
                                    }
                                }
                        )
                        #endif
                        .contentShape(Rectangle())

                    pageFooter(index: pageIndex, total: pages.count)
                        .padding(.bottom, 8)
                }
            }
            .focusable()
            .focused($paginatedFocus)
            .onAppear { paginatedFocus = true }
            .onKeyPress { press in
                handleKeyPress(press, totalPages: pages.count)
            }
            .background(
                tapZones(totalPages: pages.count)
            )
            #if os(macOS)
            .modifier(ScrollWheelPager(
                onPrev: { if currentPage > 0 { currentPage -= 1 } },
                onNext: { if currentPage + 1 < pages.count { currentPage += 1 } }
            ))
            #endif
        }
    }

    private func pageView(pages: [String], pageIndex: Int) -> some View {
        let pageText = pages[pageIndex]
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if pageIndex == 0 { chapterTitleHeader }
                Text(pageText)
                    .font(bodyFont)
                    .lineSpacing(settings.readerLineSpacing)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, settings.readerMargin)
            .padding(.vertical, 24)
            .frame(maxWidth: settings.readerColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollDisabled(true)
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
                .onTapGesture {
                    if currentPage > 0 { currentPage -= 1 }
                }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if currentPage + 1 < totalPages { currentPage += 1 }
                }
        }
    }

    private func handleKeyPress(_ press: KeyPress, totalPages: Int) -> KeyPress.Result {
        switch press.key {
        case .leftArrow, .pageUp, "k":
            if currentPage > 0 { currentPage -= 1 }
            return .handled
        case .rightArrow, .pageDown, .space, "j":
            if currentPage + 1 < totalPages { currentPage += 1 }
            return .handled
        case .home:
            currentPage = 0
            return .handled
        case .end:
            currentPage = max(0, totalPages - 1)
            return .handled
        default:
            return .ignored
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
    .environment(AppSettings())
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
    .environment(settings)
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
    .environment(settings)
}
#endif
