#if os(macOS)
import AppKit

/// The language list of the Models screen, pushed from it: the system languages first, then the most popular
/// ones, then every other language alphabetically (CONTEXT.md, "Models screen language order").
@MainActor
final class MacModelsLanguagesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
        case header(String)
        case language(tag: String, name: String, modelCount: Int)
    }

    private let items: [Item]
    var onSelect: ((String) -> Void)?
    private let table = NSTableView()

    init(languages: [CatalogLanguage], systemPreferred: [String] = Locale.preferredLanguages,
         uiLocale: Locale = .current) {
        let order = ModelLanguageOrder.sections(languages: languages, systemPreferred: systemPreferred, uiLocale: uiLocale)
        let counts = Dictionary(languages.map { ($0.tag, $0.modelCount) }, uniquingKeysWith: { first, _ in first })
        func rows(_ title: String, _ tags: [String]) -> [Item] {
            tags.isEmpty ? [] : [.header(title)] + tags.map {
                let name = ModelLanguageOrder.displayName($0, in: uiLocale)
                return .language(tag: $0, name: name.prefix(1).uppercased() + name.dropFirst(), modelCount: counts[$0] ?? 0)
            }
        }
        items = rows(L10n.string("models.languages.system"), order.system)
            + rows(L10n.string("models.languages.popular"), order.popular)
            + rows(L10n.string("models.languages.all"), order.others)
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("models.languages")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityIdentifier("models.languages.table")
        // A zero-sized root would shrink a hosting window and leave the table without rows.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        view = scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .language = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .preferredFont(forTextStyle: .headline)
            label.setAccessibilityRole(.staticText)
            return label
        case .language(let tag, let name, let count):
            let title = NSTextField(labelWithString: name)
            title.setAccessibilityIdentifier("models.languages.row.\(tag)")
            let detail = NSTextField(labelWithString: ModelLanguageOrder.modelCountText(count))
            detail.textColor = .readableSecondaryLabel
            detail.font = .preferredFont(forTextStyle: .caption1)
            // Each language opens its page, so it carries a disclosure chevron, as on the iPhone 16e.
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.setAccessibilityIdentifier("models.languages.chevron.\(tag)")
            let stack = NSStackView(views: [title, NSView(), detail, chevron])
            stack.orientation = .horizontal
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            stack.setAccessibilityElement(true)
            stack.setAccessibilityLabel("\(name), \(detail.stringValue)")
            stack.setAccessibilityRole(.button)
            return stack
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard items.indices.contains(row), case .language(let tag, _, _) = items[row] else { return }
        onSelect?(tag)
    }
}
#endif
