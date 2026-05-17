import SwiftUI

/// Compact reader-settings sheet — theme, font family, font size,
/// line spacing. Presented as a half-height detent from the reader
/// toolbar (replaces the old in-toolbar horizontal scroll bar).
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            Form {
                // MARK: Theme
                Section(L10n.string("readerSettings.theme")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(ReaderTheme.allCases.filter { $0 != .custom }) { theme in
                            themeCircle(theme)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: Font
                Section(L10n.string("readerSettings.font")) {
                    Picker(L10n.string("readerSettings.family"), selection: $settings.readerFontFamily) {
                        ForEach(ReaderFontFamily.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(L10n.string("readerSettings.size"))
                        Spacer()
                        Button {
                            if settings.readerFontSize > 0 { settings.readerFontSize -= 1 }
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(settings.readerFontSize <= 0)
                        .accessibilityLabel(L10n.string("readerSettings.decreaseFontSize"))
                        Text("\(Int(settings.readerPointSize))pt")
                            .monospacedDigit()
                            .frame(width: 50)
                        Button {
                            if settings.readerFontSize < 4 { settings.readerFontSize += 1 }
                        } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(settings.readerFontSize >= 4)
                        .accessibilityLabel(L10n.string("readerSettings.increaseFontSize"))
                    }
                }

                // MARK: Layout
                Section(L10n.string("readerSettings.layout")) {
                    Picker(L10n.string("readerSettings.mode"), selection: $settings.readerLayout) {
                        ForEach(ReaderLayout.allCases) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(L10n.string("readerSettings.lineSpacing"))
                        Spacer()
                        Slider(
                            value: $settings.readerLineSpacing,
                            in: 0...16,
                            step: 2
                        )
                        .frame(width: 140)
                    }

                    HStack {
                        Text(L10n.string("readerSettings.margin"))
                        Spacer()
                        Slider(
                            value: $settings.readerMargin,
                            in: 16...80,
                            step: 4
                        )
                        .frame(width: 140)
                    }
                }
            }
            .navigationTitle(L10n.string("readerSettings.title"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("readerSettings.done")) { dismiss() }
                }
            }
        }
        .compatPresentationDetents()
    }

    @ViewBuilder
    private func themeCircle(_ theme: ReaderTheme) -> some View {
        let isSelected = settings.readerTheme == theme
        Button {
            settings.readerTheme = theme
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(themePreviewColor(theme))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    )
                Text(theme.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func themePreviewColor(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto:      return .platformSystemBackground
        case .light:     return .white
        case .sepia:     return Color(red: 0.97, green: 0.94, blue: 0.88)
        case .parchment: return Color(red: 0.96, green: 0.93, blue: 0.85)
        case .paper:     return Color(red: 0.91, green: 0.89, blue: 0.84)
        case .dark:      return Color(red: 0.11, green: 0.11, blue: 0.12)
        case .black:     return .black
        case .custom:    return .gray
        }
    }
}
