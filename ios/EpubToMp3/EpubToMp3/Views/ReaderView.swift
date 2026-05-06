import SwiftUI

/// Side-by-side EPUB reader synchronised with audio playback.
///
/// Renders one chapter at a time as a `ScrollViewReader` + `LazyVStack`
/// of sentence rows. The current sentence (driven by `SyncEngine`) gets
/// a yellow background; the scroll view auto-scrolls to keep it
/// roughly centred unless the user has dragged manually OR disabled
/// auto-scroll in the toolbar.
///
/// Contract:
///   - Owns no networking — receives the chapter spans + current
///     sentence id from the parent (`PlayerReaderView`).
///   - Reads typography from `AppSettings` so the toolbar buttons
///     mutate the global preference and persist via `@AppStorage`.
struct ReaderView: View {
    let chapter: EbookFulltext.Chapter
    let spans: [SentenceSpan]
    let currentSentenceId: String?
    let onJumpToSentence: ((SentenceSpan) -> Void)?

    @Environment(AppSettings.self) private var settings
    @State private var userIsScrolling: Bool = false
    @State private var lastAutoScrollAt: Date = .distantPast

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
        @Bindable var bindable = settings
        return VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(themeBackground)
        .foregroundStyle(themeForeground)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        @Bindable var bindable = settings
        return HStack(spacing: 16) {
            // Font size — A− / A+
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

            Picker("Theme", selection: $bindable.readerTheme) {
                ForEach(ReaderTheme.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)

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

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    chapterTitleHeader
                    ForEach(spans) { span in
                        sentenceRow(span)
                            .id(span.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in userIsScrolling = true }
                    .onEnded { _ in
                        // Re-arm auto-scroll after the user lifts;
                        // we wait a moment so the inertia doesn't
                        // immediately fight with `scrollTo`.
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
            .lineSpacing(6)
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
        case .light: return Color(.systemBackground)
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.85)
        case .dark:  return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .black: return .black
        }
    }

    private var themeForeground: Color {
        switch settings.readerTheme {
        case .light: return .primary
        case .sepia: return Color(red: 0.20, green: 0.15, blue: 0.10)
        case .dark:  return Color(white: 0.92)
        case .black: return Color(white: 0.95)
        }
    }
}
