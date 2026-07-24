#if os(iOS)
import Combine
import UIKit

@MainActor
final class TelemetryScreenController: UITableViewController {
    private let settings: AppSettings
    private let viewModel = TelemetryViewModel()
    private var cancellables: Set<AnyCancellable> = []
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init(style: .insetGrouped)
        title = L10n.string("settings.telemetry")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(refreshTapped)
        )
        bindViewModel()
        refresh()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .engines:
            return max(1, viewModel.perEngine.count)
        case .error:
            return 1
        case .timestamp:
            return 1
        case .raw:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .engines:
            return L10n.string("telemetry.engines")
        case .error:
            return nil
        case .timestamp:
            return nil
        case .raw:
            return L10n.string("telemetry.rawPayload")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.selectionStyle = .none

        switch visibleSections[indexPath.section] {
        case .engines:
            if viewModel.isLoading && viewModel.perEngine.isEmpty {
                content.text = nil
                cell.contentConfiguration = content
                cell.accessoryView = UIActivityIndicatorView(style: .medium)
                (cell.accessoryView as? UIActivityIndicatorView)?.startAnimating()
                return cell
            }
            cell.accessoryView = nil
            if viewModel.perEngine.isEmpty {
                content.text = String(localized: "telemetry.noSamples")
                content.textProperties.color = .secondaryLabel
            } else {
                let row = viewModel.perEngine[indexPath.row]
                content.text = row.engine
                if let cps = row.charsPerSecond {
                    var lines = [L10n.string("telemetry.charsPerSecond", String(Int(cps.rounded())))]
                    if let n = row.samples {
                        lines.append(L10n.string("telemetry.chaptersCount", n))
                    }
                    content.secondaryText = lines.joined(separator: "\n")
                } else {
                    content.secondaryText = "—"
                }
            }
        case .error:
            cell.accessoryView = nil
            content.text = viewModel.error
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
        case .timestamp:
            cell.accessoryView = nil
            content.text = L10n.string("telemetry.lastFetched")
            content.secondaryText = viewModel.lastFetched.map(Self.formatTimestamp)
        case .raw:
            cell.accessoryView = nil
            content.text = viewModel.rawJSON
            content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        cell.contentConfiguration = content
        return cell
    }

    private enum Section {
        case engines
        case error
        case timestamp
        case raw
    }

    private var visibleSections: [Section] {
        var sections: [Section] = [.engines]
        if viewModel.error != nil { sections.append(.error) }
        if viewModel.lastFetched != nil { sections.append(.timestamp) }
        if !viewModel.rawJSON.isEmpty { sections.append(.raw) }
        return sections
    }

    private func bindViewModel() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.navigationItem.rightBarButtonItem?.isEnabled = !(self?.viewModel.isLoading ?? false)
                    self?.tableView.reloadData()
                }
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        Task { await viewModel.reload(client: client) }
    }

    private static func formatTimestamp(_ when: Date) -> String {
        if #available(iOS 15, *) {
            return when.formatted(date: .omitted, time: .standard)
        }
        return timestampFormatter.string(from: when)
    }

    @objc
    private func refreshTapped() {
        refresh()
    }
}
#endif
