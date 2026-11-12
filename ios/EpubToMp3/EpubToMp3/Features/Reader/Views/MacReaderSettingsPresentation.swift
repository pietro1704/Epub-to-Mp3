#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

@MainActor
final class MacReaderSettingsPresentation: NSObject {
    private let settings: AppSettings
    private let settingsPopover: NSPopover

    init(settings: AppSettings, popover: NSPopover) {
        self.settings = settings
        settingsPopover = popover
        super.init()
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
        let margin = MacPointPresetControl(presets: PointPresetScale.macMargin,
            current: settings.readerMargin, title: L10n.string("reader.margins"),
            identifier: "readerSettings.margin") { [weak settings] in settings?.readerMargin = $0 }
        let kerning = MacPointPresetControl(presets: PointPresetScale.macKerning,
            current: settings.readerLetterSpacing, title: L10n.string("reader.kerning"),
            identifier: "readerSettings.kerning") { [weak settings] in settings?.readerLetterSpacing = $0 }

        let columns = NSPopUpButton()
        columns.addItems(withTitles: ["1", "2", "3", "4"])
        columns.selectItem(withTitle: String(settings.readerColumns))
        columns.setAccessibilityLabel(L10n.string("reader.columns"))
        columns.setAccessibilityIdentifier("readerSettings.columns")
        columns.target = self
        columns.action = #selector(columnsChanged(_:))

        let stack = NSStackView(views: [label("reader.font"), font, sizeControl, label("reader.theme"), theme, label("reader.layout"), layout, label("reader.margins"), margin, label("reader.kerning"), kerning, label("reader.columns"), columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
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
        settings.readerLayout = ReaderLayout.allCases[sender.indexOfSelectedItem]
    }

    @objc private func columnsChanged(_ sender: NSPopUpButton) {
        settings.readerColumns = Int(sender.titleOfSelectedItem ?? "1") ?? 1
    }


}
#endif
