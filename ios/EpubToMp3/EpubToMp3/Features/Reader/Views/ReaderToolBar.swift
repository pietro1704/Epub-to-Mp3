#if os(iOS)
import UIKit

@MainActor
final class ReaderToolBar: NSObject {
    private let preference: ReaderToolPreference
    private let perform: (ReaderTool) -> Void
    private lazy var recent = UIBarButtonItem(title: "Aa", style: .plain, target: self, action: #selector(useRecent))
    private lazy var more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: makeMenu())

    init(defaults: UserDefaults = .standard, perform: @escaping (ReaderTool) -> Void) {
        preference = ReaderToolPreference(defaults: defaults)
        self.perform = perform
        super.init()
    }

    var items: [UIBarButtonItem] {
        updateRecent()
        more.accessibilityIdentifier = "reader.more"
        more.accessibilityLabel = L10n.string("reader.more")
        return [more, recent]
    }

    func choose(_ tool: ReaderTool) {
        preference.recent = tool
        updateRecent()
        perform(tool)
    }

    @objc private func useRecent() { choose(preference.recent) }

    private func updateRecent() {
        let tool = preference.recent
        recent.title = tool == .appearance ? "Aa" : nil
        recent.image = tool == .appearance ? nil : UIImage(systemName: tool.symbol)
        recent.accessibilityLabel = tool.title
        recent.accessibilityIdentifier = tool.accessibilityIdentifier
        more.menu = makeMenu()
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: ReaderTool.allCases.map { tool in
            UIAction(title: tool.title, image: UIImage(systemName: tool.symbol), identifier: UIAction.Identifier(tool.accessibilityIdentifier)) { [weak self] _ in self?.choose(tool) }
        })
    }
}
#elseif os(macOS)
import AppKit

@MainActor
final class MacReaderToolBar: NSObject {
    private let preference: ReaderToolPreference
    private let perform: (ReaderTool, NSButton) -> Void
    let recent = NSButton()
    let more = NSButton()

    init(defaults: UserDefaults = .standard, perform: @escaping (ReaderTool, NSButton) -> Void) {
        preference = ReaderToolPreference(defaults: defaults)
        self.perform = perform
        super.init()
        recent.target = self
        recent.action = #selector(useRecent)
        more.target = self
        more.action = #selector(showMore)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        more.setAccessibilityIdentifier("reader.more")
        more.setAccessibilityLabel(L10n.string("reader.more"))
        for button in [recent, more] { button.bezelStyle = .texturedRounded }
        more.menu = makeMenu()
        updateRecent()
    }

    private func updateRecent() {
        let tool = preference.recent
        recent.title = tool == .appearance ? "Aa" : ""
        recent.image = tool == .appearance ? nil : NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
        recent.setAccessibilityLabel(tool.title)
        recent.setAccessibilityIdentifier(tool.accessibilityIdentifier)
        recent.toolTip = tool.title
    }

    @objc private func useRecent() { perform(preference.recent, recent) }
    @objc private func showMore() {
        more.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
    }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for tool in ReaderTool.allCases {
            let item = NSMenuItem(title: tool.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func choose(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let tool = ReaderTool(rawValue: raw) else { return }
        preference.recent = tool
        updateRecent()
        perform(tool, recent)
    }
}
#endif
