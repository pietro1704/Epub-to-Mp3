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
        fontSizeSlider.maxValue = 4
        fontSizeSlider.numberOfTickMarks = 5
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
        for (control, key) in [(fontSizeSlider, "settings.fontSize"), (fontPopup, "settings.font"),
                               (themePopup, "settings.theme"), (layoutPopup, "settings.layout")] as [(NSControl, String)] {
            control.setAccessibilityLabel(L10n.string(key))
            control.setAccessibilityIdentifier(key)
        }
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
    }
}
#endif
