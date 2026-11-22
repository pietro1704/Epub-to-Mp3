#if os(macOS)
import AppKit

@MainActor
final class MacPublicDomainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let discovery: PublicDomainDiscovery
    private let onOpen: (BookEntity) -> Void
    private let searchField = NSSearchField()
    private let language = NSPopUpButton()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let download = NSButton()
    private let source = NSButton()
    private let more = NSButton()
    private let cancel = NSButton()
    private let close = NSButton()
    private let open = NSButton()

    init(discovery: PublicDomainDiscovery, onOpen: @escaping (BookEntity) -> Void) {
        self.discovery = discovery
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("discovery.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        preferredContentSize = view.frame.size
        searchField.placeholderString = L10n.string("discovery.search")
        searchField.setAccessibilityIdentifier("discovery.search")
        searchField.setAccessibilityLabel(L10n.string("discovery.search"))
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(search)
        language.addItems(withTitles: PublicDomainCatalog.Language.allCases.map(\.label))
        language.setAccessibilityLabel(L10n.string("discovery.language"))
        language.target = self
        language.action = #selector(search)
        let searchButton = NSButton()
        configure(searchButton, "discovery.searchAction", #selector(search))
        let filters = NSStackView(views: [searchField, language, searchButton])
        filters.orientation = .horizontal
        let rights = NSTextField(wrappingLabelWithString: L10n.string("discovery.gutenbergRights"))
        let brazil = NSButton()
        configure(brazil, "discovery.brazilCatalog", #selector(openBrazil))
        configure(download, "discovery.download", #selector(downloadSelected))
        configure(source, "discovery.source", #selector(openSource))
        configure(more, "discovery.more", #selector(loadMore))
        configure(cancel, "library.cancel", #selector(cancelTask))
        configure(open, "library.openBook", #selector(openImported))
        configure(close, "discovery.close", #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        let rowActions = NSStackView(views: [download, source, more])
        let sheetActions = NSStackView(views: [cancel, open, close])
        status.setAccessibilityIdentifier("discovery.status")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        table.headerView = nil
        table.setAccessibilityLabel(L10n.string("discovery.title"))
        table.rowHeight = 62
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("edition"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        let stack = NSStackView(views: [rights, brazil, filters, scroll, rowActions, status, sheetActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            rights.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filters.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        discovery.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func configure(_ button: NSButton, _ key: String, _ action: Selector) {
        button.title = L10n.string(key)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private var selectedEdition: PublicDomainCatalog.Edition? {
        discovery.editions.indices.contains(table.selectedRow) ? discovery.editions[table.selectedRow] : nil
    }

    private func refresh() {
        let idle = discovery.activity == .idle
        table.reloadData()
        searchField.isEnabled = idle
        language.isEnabled = idle
        more.isHidden = !discovery.hasMore
        more.isEnabled = idle
        cancel.isHidden = idle || discovery.activity == .importing
        open.isHidden = discovery.importedBook == nil
        close.isEnabled = discovery.activity != .importing
        status.stringValue = discovery.message
        refreshSelection()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }

    private func refreshSelection() {
        download.isEnabled = discovery.activity == .idle && selectedEdition != nil
        source.isEnabled = selectedEdition != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { discovery.editions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let edition = discovery.editions[row]
        let title = NSTextField(labelWithString: edition.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let detail = NSTextField(labelWithString: edition.detail)
        detail.textColor = .secondaryLabelColor
        let attribution = NSTextField(labelWithString: edition.attribution)
        attribution.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail, attribution])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    @objc private func search() {
        guard language.indexOfSelectedItem >= 0 else { return }
        discovery.search(searchField.stringValue, language: PublicDomainCatalog.Language.allCases[language.indexOfSelectedItem])
    }

    @objc private func loadMore() { discovery.loadNextPage() }
    @objc private func cancelTask() { discovery.cancel() }
    @objc private func openBrazil() { NSWorkspace.shared.open(PublicDomainCatalog.brazilianCatalog) }

    @objc private func downloadSelected() {
        guard let edition = selectedEdition else { return }
        discovery.download(edition)
    }

    @objc private func openSource() {
        guard let edition = selectedEdition else { return }
        NSWorkspace.shared.open(edition.source)
    }

    @objc private func closeSheet() {
        discovery.cancel()
        dismiss(nil)
    }

    @objc private func openImported() {
        guard let book = discovery.importedBook else { return }
        dismiss(nil)
        onOpen(book)
    }
}
#endif
