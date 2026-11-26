#if os(macOS)
import AppKit
import PDFKit
import Combine

/// A scroll view opens an unflipped document at its bottom.
private final class TopAnchoredStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class MacReaderSettingsPresentation: NSObject {
    private let settings: AppSettings
    private let settingsPopover: NSPopover
    private weak var pageNumbersToggle: NSButton?
    private let bookPreferences: BookReadingPreferencesStore

    init(settings: AppSettings, popover: NSPopover, bookPreferences: BookReadingPreferencesStore = .shared) {
        self.settings = settings
        settingsPopover = popover
        self.bookPreferences = bookPreferences
        super.init()
    }

    /// Builds the popover content without showing it.
    func prepareForTesting() { configureSettingsPopover() }

    /// The mode on top (default for every book, or this book only) and, with a book open, the choice to keep
    /// these settings for this book only.
    private func scopeViews() -> [NSView] {
        let mode = NSTextField(labelWithString: L10n.string(settings.readingPreferenceModeTitleKey))
        mode.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        mode.setAccessibilityIdentifier("readerSettings.scope.mode")
        guard settings.isInBookScope else { return [mode] }
        let hint = NSTextField(wrappingLabelWithString: L10n.string(settings.readingPreferenceModeHintKey))
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .readableSecondaryLabel
        hint.preferredMaxLayoutWidth = 230
        let bookOnly = NSButton(checkboxWithTitle: L10n.string("readerSettings.scope.toggle"), target: self,
                                action: #selector(scopeChanged(_:)))
        bookOnly.state = settings.isBookSpecific ? .on : .off
        bookOnly.setAccessibilityIdentifier("readerSettings.scope.bookOnly")
        return [mode, hint, bookOnly]
    }

    @objc private func scopeChanged(_ sender: NSButton) {
        if sender.state == .on { settings.useOnlyForThisBook(store: bookPreferences) }
        else { settings.useDefaultForThisBook(store: bookPreferences) }
        // The controls show the values of the new mode.
        configureSettingsPopover()
    }

    private func configureSettingsPopover() {
        let font = NSPopUpButton()
        ReaderFontCatalog.configure(font, selected: settings.selectedReaderFontFamily)
        font.setAccessibilityLabel(L10n.string("reader.font"))
        font.setAccessibilityIdentifier("readerSettings.font")
        font.target = self
        font.action = #selector(fontChanged(_:))

        let theme = NSPopUpButton()
        theme.addItems(withTitles: ReaderTheme.allCases.map(\.displayName))
        theme.selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0)
        theme.setAccessibilityLabel(L10n.string("reader.theme"))
        theme.setAccessibilityIdentifier("readerSettings.theme")
        theme.target = self
        theme.action = #selector(themeChanged(_:))

        let layout = NSPopUpButton()
        layout.addItems(withTitles: ReaderLayout.allCases.map(\.displayName))
        layout.selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0)
        layout.setAccessibilityLabel(L10n.string("reader.layout"))
        layout.setAccessibilityIdentifier("readerSettings.layout")
        layout.target = self
        layout.action = #selector(layoutChanged(_:))

        let sizeControl = MacPointPresetControl(presets: PointPresetScale.font,
            current: Double(settings.readerPointSize), title: L10n.string("settings.fontSize"),
            identifier: "readerSettings.fontSize") { [weak settings] value in
                settings?.readerFontSize = PointPresetScale.nearestIndex(to: value, in: PointPresetScale.font)
            }
        let alignment = NSPopUpButton()
        alignment.addItems(withTitles: ReaderTextAlignment.allCases.map(\.displayName))
        alignment.selectItem(at: ReaderTextAlignment.allCases.firstIndex(of: settings.readerTextAlignment) ?? 0)
        alignment.setAccessibilityLabel(L10n.string("readerSettings.alignment"))
        alignment.setAccessibilityIdentifier("readerSettings.alignment")
        alignment.target = self
        alignment.action = #selector(alignmentChanged(_:))
        let lineSpacing = MacPointPresetControl(presets: PointPresetScale.lineSpacing,
            current: settings.readerLineSpacing, title: L10n.string("readerSettings.lineSpacing"),
            identifier: "readerSettings.lineSpacing") { [weak settings] in settings?.readerLineSpacing = $0 }
        let margin = MacPointPresetControl(presets: PointPresetScale.macMargin,
            current: settings.readerMargin, title: L10n.string("reader.margins"),
            identifier: "readerSettings.margin") { [weak settings] in settings?.readerMargin = $0 }
        let kerning = MacPointPresetControl(presets: PointPresetScale.macKerning,
            current: settings.readerLetterSpacing, title: L10n.string("reader.kerning"),
            identifier: "readerSettings.kerning") { [weak settings] in settings?.readerLetterSpacing = $0 }

        let pageNumbers = NSButton(checkboxWithTitle: L10n.string("readerSettings.showPageNumbers"), target: self,
                                   action: #selector(pageNumbersChanged(_:)))
        pageNumbers.state = settings.readerShowPageNumbers ? .on : .off
        pageNumbers.setAccessibilityIdentifier("readerSettings.showPageNumbers")
        pageNumbers.isHidden = settings.readerLayout != .paginated
        pageNumbersToggle = pageNumbers

        let columns = NSPopUpButton()
        columns.addItems(withTitles: ["1", "2", "3", "4"])
        columns.selectItem(withTitle: String(settings.readerColumns))
        columns.setAccessibilityLabel(L10n.string("reader.columns"))
        columns.setAccessibilityIdentifier("readerSettings.columns")
        columns.target = self
        columns.action = #selector(columnsChanged(_:))

        let stack = TopAnchoredStackView(views: scopeViews() + [label("reader.font"), font, sizeControl, label("reader.theme"), theme, label("reader.layout"), layout, pageNumbers, label("readerSettings.alignment"), alignment, label("readerSettings.lineSpacing"), lineSpacing, label("reader.margins"), margin, label("reader.kerning"), kerning, label("reader.columns"), columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        // A leading-aligned stack gives a slider no width of its own.
        for control in [sizeControl, lineSpacing, margin, kerning] {
            control.widthAnchor.constraint(equalToConstant: 232).isActive = true
        }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        let controller = NSViewController()
        controller.view = scrollView
        settingsPopover.contentViewController = controller
        settingsPopover.contentSize = NSSize(width: 260, height: 420)
        settingsPopover.behavior = .transient
    }

    private func label(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.string(key))
        field.setAccessibilityRole(.staticText)
        return field
    }

    func showSettings(_ sender: NSButton) {
        configureSettingsPopover()
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String, let family = ReaderFontFamily(rawValue: key) else { return }
        settings.readerFontFamily = family
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.readerTheme = ReaderTheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        let selected = ReaderLayout.allCases[sender.indexOfSelectedItem]
        settings.readerLayout = selected
        pageNumbersToggle?.isHidden = selected != .paginated
    }

    @objc private func alignmentChanged(_ sender: NSPopUpButton) {
        settings.readerTextAlignment = ReaderTextAlignment.allCases[sender.indexOfSelectedItem]
    }

    @objc private func pageNumbersChanged(_ sender: NSButton) {
        settings.readerShowPageNumbers = sender.state == .on
    }

    @objc private func columnsChanged(_ sender: NSPopUpButton) {
        settings.readerColumns = Int(sender.titleOfSelectedItem ?? "1") ?? 1
    }


}
#endif
