#if os(macOS)
import AppKit

@MainActor
final class MacJobsListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var sessions: [SessionRecord] = []
    private let tableView = NSTableView()
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var reloadTask: Task<Void, Never>?
    private var reloadID = UUID()

    deinit { reloadTask?.cancel() }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("jobs.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!,
                               target: self,
                               action: #selector(refreshTapped))
        refresh.bezelStyle = .texturedRounded
        refresh.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(refresh)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = L10n.string("jobs.book")
        titleColumn.width = 220
        titleColumn.resizingMask = .userResizingMask
        let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailColumn.title = L10n.string("jobs.status")
        detailColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(titleColumn)
        tableView.addTableColumn(detailColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        scroll.documentView = tableView
        view.addSubview(scroll)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            refresh.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            refresh.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            refresh.widthAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        reload()
    }

    @objc private func refreshTapped() { reload() }

    private func reload() {
        reloadTask?.cancel()
        let requestID = UUID()
        reloadID = requestID
        spinner.startAnimation(nil)
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
            .appendingPathComponent("EpubToMp3/.logs/conversions.jsonl")
        reloadTask = Task { [weak self] in
            do {
                let snapshot = try await ConversionHistoryReader.loadLatest(from: logURL)
                guard let self, !Task.isCancelled, self.reloadID == requestID else { return }
                self.spinner.stopAnimation(nil)
                self.sessions = snapshot.sessions
                self.tableView.reloadData()
                if self.sessions.isEmpty {
                    self.showMessage(snapshot.budgetExhausted
                        ? L10n.string("jobs.historyReadLimit")
                        : L10n.string("jobs.noConversionsDescription"))
                } else {
                    self.tableView.isHidden = false
                    self.messageLabel.isHidden = true
                }
            } catch {
                guard let self, !Task.isCancelled, self.reloadID == requestID else { return }
                let missing = (error as NSError).domain == NSCocoaErrorDomain
                    && (error as NSError).code == NSFileReadNoSuchFileError
                self.showMessage(missing ? L10n.string("jobs.noConversionsDescription") : error.localizedDescription)
            }
        }
    }

    private func showMessage(_ message: String) {
        spinner.stopAnimation(nil)
        tableView.isHidden = true
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        if cell.textField == nil {
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let session = sessions[row]
        if identifier.rawValue == "title" {
            label.stringValue = session.bookTitle
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        } else {
            let outcome = session.outcome?.capitalized ?? "—"
            let engine = session.engine ?? ""
            let chapters = session.chaptersConverted.map { L10n.string("jobs.chaptersAbbrev", $0) } ?? ""
            label.stringValue = [outcome, engine, chapters, String(session.timestamp.prefix(19))]
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
            label.textColor = .secondaryLabelColor
        }
        return cell
    }
}
#endif
