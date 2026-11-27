#if os(macOS)
import AppKit

/// The "Reading preferences" page opened from Settings › Reader, like the
/// Linux client: the default appearance applied to every book.
@MainActor
final class MacReadingPreferencesViewController: NSViewController {
    private let settings: AppSettings
    private let fontSizeSlider = NSSlider()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let alignmentPopup = NSPopUpButton()
    private let pageTurnPopup = NSPopUpButton()
    private let pageNumbersToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Rows that only make sense with pages.
    private var paginatedRows: [NSView] = []

    init(settings: AppSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("settings.readingPreferences")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        refresh()
    }

    private func configureControls() {
        fontSizeSlider.minValue = 0
        fontSizeSlider.maxValue = Double(ReaderFontScale.maximumStep)
        fontSizeSlider.numberOfTickMarks = ReaderFontScale.maximumStep + 1
        fontSizeSlider.allowsTickMarkValuesOnly = true
        fontSizeSlider.isContinuous = true
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeChanged(_:))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        themePopup.addItems(withTitles: ReaderTheme.allCases.map(\.displayName))
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        layoutPopup.addItems(withTitles: ReaderLayout.allCases.map(\.displayName))
        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChanged(_:))
        alignmentPopup.addItems(withTitles: ReaderTextAlignment.allCases.map(\.displayName))
        alignmentPopup.target = self
        alignmentPopup.action = #selector(alignmentChanged(_:))
        pageTurnPopup.addItems(withTitles: PageTurnStyle.macCases.map(\.displayName))
        pageTurnPopup.target = self
        pageTurnPopup.action = #selector(pageTurnChanged(_:))
        pageNumbersToggle.target = self
        pageNumbersToggle.action = #selector(pageNumbersChanged(_:))
        let original = NSButton(title: L10n.string("settings.originalTypography.restore"), target: self,
                                action: #selector(useOriginalTypography))
        for (control, id, key) in [
            (fontSizeSlider, "settings.fontSize", "settings.fontSize"), (fontPopup, "settings.font", "settings.font"),
            (themePopup, "settings.theme", "settings.theme"), (layoutPopup, "settings.layout", "settings.layout"),
            (alignmentPopup, "settings.alignment", "readerSettings.alignment"),
            (pageTurnPopup, "settings.pageTurnStyle", "readerSettings.pageTurnStyle"),
            (pageNumbersToggle, "settings.pageNumbers", "readerSettings.showPageNumbers"),
            (original, "settings.originalTypography", "settings.originalTypography"),
        ] as [(NSControl, String, String)] {
            control.setAccessibilityLabel(L10n.string(key))
            control.setAccessibilityIdentifier(id)
        }
        let lineSpacing = MacPointPresetControl(presets: PointPresetScale.lineSpacing,
            current: settings.readerLineSpacing, title: L10n.string("readerSettings.lineSpacing"),
            identifier: "settings.lineSpacing") { [weak settings] in settings?.readerLineSpacing = $0 }
        let margin = MacPointPresetControl(presets: PointPresetScale.macMargin,
            current: settings.readerMargin, title: L10n.string("reader.margins"),
            identifier: "settings.margin") { [weak settings] in settings?.readerMargin = $0 }
        for control in [lineSpacing, margin] {
            control.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        let pageTurnRow = MacSettingsSections.row(title: L10n.string("readerSettings.pageTurnStyle"),
                                                  symbol: "book.pages", accessory: pageTurnPopup)
        let pageNumbersRow = MacSettingsSections.row(title: L10n.string("readerSettings.showPageNumbers"),
                                                     symbol: "number", accessory: pageNumbersToggle)
        paginatedRows = [pageTurnRow, pageNumbersRow]
        let sizeControl = NSStackView(views: [fontSizeSlider, fontSizeLabel])
        sizeControl.spacing = 8
        sizeControl.alignment = .centerY
        fontSizeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let rows = [
            MacSettingsSections.row(title: L10n.string("settings.theme"), symbol: "paintpalette", accessory: themePopup),
            MacSettingsSections.row(title: L10n.string("settings.font"), symbol: "textformat", accessory: fontPopup),
            MacSettingsSections.row(title: L10n.string("settings.fontSize"), symbol: "textformat.size",
                                    accessory: sizeControl),
            MacSettingsSections.row(title: L10n.string("settings.layout"), symbol: "doc.text", accessory: layoutPopup),
            MacSettingsSections.row(title: L10n.string("readerSettings.lineSpacing"),
                                    symbol: "arrow.up.and.down.text.horizontal", accessory: lineSpacing),
            MacSettingsSections.row(title: L10n.string("reader.margins"), symbol: "arrow.left.and.right.square",
                                    accessory: margin),
            MacSettingsSections.row(title: L10n.string("readerSettings.alignment"), symbol: "text.justify",
                                    accessory: alignmentPopup),
            pageTurnRow,
            pageNumbersRow,
            MacSettingsSections.row(title: L10n.string("settings.originalTypography"),
                                    symbol: "arrow.counterclockwise", accessory: original),
        ]
        let form = NSStackView(views: [
            MacSettingsSections.header(L10n.string("settings.readingPreferencesSubtitle")),
            MacSettingsSections.card(rows),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.arrangedSubviews.last?.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        MacScrollableStack.install(form, in: view)
    }

    private func refresh() {
        fontSizeSlider.integerValue = settings.readerFontSize
        fontSizeLabel.stringValue = PointPresetScale.label(Double(settings.readerPointSize))
        ReaderFontCatalog.configure(fontPopup, selected: settings.selectedReaderFontFamily)
        select(ReaderTheme.allCases.firstIndex(of: settings.readerTheme), in: themePopup)
        select(ReaderLayout.allCases.firstIndex(of: settings.readerLayout), in: layoutPopup)
        select(ReaderTextAlignment.allCases.firstIndex(of: settings.readerTextAlignment), in: alignmentPopup)
        select(PageTurnStyle.macCases.firstIndex(of: settings.pageTurnStyle.onMac), in: pageTurnPopup)
        pageNumbersToggle.state = settings.readerShowPageNumbers ? .on : .off
        showPaginatedRows()
    }

    private func showPaginatedRows() {
        let hidden = settings.readerLayout != .paginated
        for row in paginatedRows {
            row.isHidden = hidden
            // The divider above goes with its row.
            if let siblings = (row.superview as? NSStackView)?.arrangedSubviews,
               let index = siblings.firstIndex(of: row), index > 0 {
                siblings[index - 1].isHidden = hidden
            }
        }
    }

    private func select(_ index: Int?, in popup: NSPopUpButton) {
        guard let index, index < popup.numberOfItems else { return }
        popup.selectItem(at: index)
    }

    @objc private func fontSizeChanged(_ sender: NSSlider) {
        settings.readerFontSize = sender.integerValue
        fontSizeLabel.stringValue = PointPresetScale.label(Double(settings.readerPointSize))
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String,
              let family = ReaderFontFamily(rawValue: key) else { return }
        settings.readerFontFamily = family
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.readerTheme = ReaderTheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        settings.readerLayout = ReaderLayout.allCases[sender.indexOfSelectedItem]
        showPaginatedRows()
    }

    @objc private func alignmentChanged(_ sender: NSPopUpButton) {
        settings.readerTextAlignment = ReaderTextAlignment.allCases[sender.indexOfSelectedItem]
    }

    @objc private func pageTurnChanged(_ sender: NSPopUpButton) {
        settings.pageTurnStyle = PageTurnStyle.macCases[sender.indexOfSelectedItem]
    }

    @objc private func pageNumbersChanged(_ sender: NSButton) {
        settings.readerShowPageNumbers = sender.state == .on
    }

    /// The publisher's font, size, line spacing and alignment apply again, as "Original typography" does on Linux.
    @objc private func useOriginalTypography() {
        settings.readerOverrideFontFamily = false
        settings.readerOverrideFontSize = false
        settings.readerOverrideLineSpacing = false
        settings.readerOverrideTextAlignment = false
        refresh()
    }
}
#endif
