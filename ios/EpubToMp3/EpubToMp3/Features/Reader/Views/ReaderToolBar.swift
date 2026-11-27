#if os(iOS)
import UIKit

@MainActor
final class ReaderToolBar: NSObject {
    private let preference: ReaderToolPreference
    private weak var navigationItem: UINavigationItem?
    var hasFootnotes = false {
        didSet { if hasFootnotes != oldValue { refresh() } }
    }
    private let perform: (ReaderTool) -> Void
    private lazy var recent = UIBarButtonItem(title: "Aa", style: .plain, target: self, action: #selector(useRecent))
    private lazy var more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: makeMenu())

    init(defaults: UserDefaults = .standard, perform: @escaping (ReaderTool) -> Void) {
        preference = ReaderToolPreference(defaults: defaults)
        self.perform = perform
        super.init()
    }

    /// Toolbar slots of a regular-width reader; nil keeps the compact "recent tool + more" pair.
    private var regularCapacity: Int?
    private var inlineItems: [ReaderTool: UIBarButtonItem] = [:]
    private var available: [ReaderTool] { ReaderTool.allCases.filter { $0.isAvailable(hasFootnotes: hasFootnotes) } }

    /// In UIKit order: the first item is the trailing one.
    var items: [UIBarButtonItem] {
        more.accessibilityIdentifier = "reader.more"
        more.accessibilityLabel = L10n.string("reader.more")
        guard let regularCapacity else {
            updateRecent()
            more.menu = makeMenu(available)
            return preference.recent.isAvailable(hasFootnotes: hasFootnotes) ? [more, recent] : [more]
        }
        let layout = ReaderToolLayout.split(available, capacity: regularCapacity)
        more.menu = makeMenu(layout.overflow)
        return (layout.overflow.isEmpty ? [] : [more]) + layout.inline.reversed().map(inlineItem)
    }

    /// The reserved width keeps room for the back button and the title.
    func adapt(width: CGFloat, isRegularWidth: Bool) {
        let capacity = isRegularWidth ? ReaderToolLayout.capacity(width: width, reserved: 280, itemWidth: 52) : nil
        guard capacity != regularCapacity else { return }
        regularCapacity = capacity
        refresh()
    }

    private func inlineItem(_ tool: ReaderTool) -> UIBarButtonItem {
        if let item = inlineItems[tool] { return item }
        let action = UIAction(title: tool == .appearance ? "Aa" : "",
                              image: tool == .appearance ? nil : UIImage(systemName: tool.symbol)) { [weak self] _ in
            self?.choose(tool)
        }
        let item = UIBarButtonItem(primaryAction: action)
        item.accessibilityLabel = tool.title
        item.accessibilityIdentifier = tool.accessibilityIdentifier
        inlineItems[tool] = item
        return item
    }

    func install(in navigationItem: UINavigationItem?) {
        self.navigationItem = navigationItem
        if navigationItem != nil { refresh() }
    }

    func choose(_ tool: ReaderTool) {
        guard tool.isAvailable(hasFootnotes: hasFootnotes) else { return }
        preference.recent = tool
        refresh()
        perform(tool)
    }

    @objc private func useRecent() { choose(preference.recent) }

    private func refresh() {
        let updated = items
        if let navigationItem, navigationItem.rightBarButtonItems != updated {
            navigationItem.rightBarButtonItems = updated
        }
    }

    private func updateRecent() {
        let tool = preference.recent
        recent.title = tool == .appearance ? "Aa" : nil
        recent.image = tool == .appearance ? nil : UIImage(systemName: tool.symbol)
        recent.accessibilityLabel = tool.title
        recent.accessibilityIdentifier = tool.accessibilityIdentifier
    }

    private func makeMenu(_ tools: [ReaderTool]) -> UIMenu {
        UIMenu(children: tools.map { tool in
            UIAction(title: tool.title, image: UIImage(systemName: tool.symbol), identifier: UIAction.Identifier(tool.accessibilityIdentifier)) { [weak self] _ in self?.choose(tool) }
        })
    }
}
#elseif os(macOS)
import AppKit

/// Mac windows are regular width: every tool that fits is a toolbar button, the rest go to "more".
@MainActor
final class MacReaderToolBar: NSObject {
    private let preference: ReaderToolPreference
    private let perform: (ReaderTool, NSButton) -> Void
    var hasFootnotes = false {
        didSet { if hasFootnotes != oldValue { refresh() } }
    }
    let more = NSButton()
    private var buttons: [ReaderTool: NSButton] = [:]
    private var capacity = ReaderTool.allCases.count

    /// Toolbar views in reading order.
    var views: [NSView] { ReaderTool.allCases.compactMap { buttons[$0] } + [more] }

    init(defaults: UserDefaults = .standard, perform: @escaping (ReaderTool, NSButton) -> Void) {
        preference = ReaderToolPreference(defaults: defaults)
        self.perform = perform
        super.init()
        for tool in ReaderTool.allCases {
            let button = NSButton()
            button.title = tool == .appearance ? "Aa" : ""
            button.image = tool == .appearance ? nil : NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            button.setAccessibilityLabel(tool.title)
            button.setAccessibilityIdentifier(tool.accessibilityIdentifier)
            button.toolTip = tool.title
            button.target = self
            button.action = #selector(useTool(_:))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            buttons[tool] = button
        }
        more.target = self
        more.action = #selector(showMore)
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        more.setAccessibilityIdentifier("reader.more")
        more.setAccessibilityLabel(L10n.string("reader.more"))
        for button in Array(buttons.values) + [more] { button.bezelStyle = .texturedRounded }
        refresh()
    }

    /// The reserved width keeps room for the close button, the margins and a readable title.
    func adapt(width: CGFloat) {
        let updated = ReaderToolLayout.capacity(width: width, reserved: 240, itemWidth: 46)
        guard updated != capacity else { return }
        capacity = updated
        refresh()
    }

    private func refresh() {
        let layout = ReaderToolLayout.split(ReaderTool.allCases.filter { $0.isAvailable(hasFootnotes: hasFootnotes) },
                                            capacity: capacity)
        for (tool, button) in buttons { button.isHidden = !layout.inline.contains(tool) }
        more.isHidden = layout.overflow.isEmpty
        more.menu = makeMenu(layout.overflow)
    }

    @objc private func useTool(_ button: NSButton) {
        guard let tool = button.identifier.flatMap({ ReaderTool(rawValue: $0.rawValue) }) else { return }
        use(tool, anchor: button)
    }
    @objc private func showMore() {
        more.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
    }
    private func makeMenu(_ tools: [ReaderTool]) -> NSMenu {
        let menu = NSMenu()
        for tool in tools {
            let item = NSMenuItem(title: tool.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.setAccessibilityIdentifier(tool.accessibilityIdentifier)
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func choose(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let tool = ReaderTool(rawValue: raw) else { return }
        use(tool, anchor: more)
    }
    private func use(_ tool: ReaderTool, anchor: NSButton) {
        guard tool.isAvailable(hasFootnotes: hasFootnotes) else { return }
        preference.recent = tool
        perform(tool, anchor)
    }
}
#endif
