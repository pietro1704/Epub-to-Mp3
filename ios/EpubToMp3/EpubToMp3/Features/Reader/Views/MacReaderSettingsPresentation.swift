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
        font.addItems(withTitles: ReaderFontFamily.allCases.map(\.displayName))
        font.selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0)
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

        let smaller = NSButton(title: "A−", target: self, action: #selector(decreaseFont))
        let larger = NSButton(title: "A+", target: self, action: #selector(increaseFont))
        smaller.setAccessibilityLabel(L10n.string("readerSettings.decreaseFontSize"))
        larger.setAccessibilityLabel(L10n.string("readerSettings.increaseFontSize"))
        let sizeButtons = NSStackView(views: [smaller, larger])
        sizeButtons.spacing = 8
        let margin = NSPopUpButton()
        margin.addItems(withTitles: ["16", "24", "32", "48", "64"])
        margin.selectItem(withTitle: String(Int(settings.readerMargin)))
        margin.setAccessibilityLabel(L10n.string("reader.margins"))
        margin.setAccessibilityIdentifier("readerSettings.margin")
        margin.target = self
        margin.action = #selector(marginChanged(_:))

        let kerning = NSPopUpButton()
        kerning.addItems(withTitles: ["-1", "0", "0.5", "1", "2", "3"])
        kerning.selectItem(withTitle: String(settings.readerLetterSpacing))
        kerning.setAccessibilityLabel(L10n.string("reader.kerning"))
        kerning.setAccessibilityIdentifier("readerSettings.kerning")
        kerning.target = self
        kerning.action = #selector(kerningChanged(_:))

        let columns = NSPopUpButton()
        columns.addItems(withTitles: ["1", "2", "3", "4"])
        columns.selectItem(withTitle: String(settings.readerColumns))
        columns.setAccessibilityLabel(L10n.string("reader.columns"))
        columns.setAccessibilityIdentifier("readerSettings.columns")
        columns.target = self
        columns.action = #selector(columnsChanged(_:))

        let stack = NSStackView(views: [label("reader.font"), font, sizeButtons, label("reader.theme"), theme, label("reader.layout"), layout, label("reader.margins"), margin, label("reader.kerning"), kerning, label("reader.columns"), columns])
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
        if settingsPopover.contentViewController == nil { configureSettingsPopover() }
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        settings.readerFontFamily = ReaderFontFamily.allCases[sender.indexOfSelectedItem]
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.readerTheme = ReaderTheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        settings.readerLayout = ReaderLayout.allCases[sender.indexOfSelectedItem]
    }

    @objc private func marginChanged(_ sender: NSPopUpButton) {
        settings.readerMargin = Double(sender.titleOfSelectedItem ?? "24") ?? 24
    }

    @objc private func kerningChanged(_ sender: NSPopUpButton) {
        settings.readerLetterSpacing = Double(sender.titleOfSelectedItem ?? "0") ?? 0
    }

    @objc private func columnsChanged(_ sender: NSPopUpButton) {
        settings.readerColumns = Int(sender.titleOfSelectedItem ?? "1") ?? 1
    }

    @objc private func decreaseFont() { settings.readerFontSize -= 1 }
    @objc private func increaseFont() { settings.readerFontSize += 1 }

}
#endif
