#if os(iOS)
import Combine
import SwiftUI
import UIKit

struct ConversionStatusScreenHost: UIViewControllerRepresentable {
    @ObservedObject var status: ConversionStatus
    let bookTitle: String
    let onCancel: () -> Void
    let onRetry: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: ConversionStatusScreenController(
                status: status,
                bookTitle: bookTitle,
                onCancel: onCancel,
                onRetry: onRetry
            )
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        (controller.viewControllers.first as? ConversionStatusScreenController)?
            .update(status: status, bookTitle: bookTitle, onCancel: onCancel, onRetry: onRetry)
    }
}

@MainActor
final class ConversionStatusScreenController: UITableViewController {
    private let status: ConversionStatus
    private var bookTitle: String
    private var onCancel: () -> Void
    private var onRetry: () -> Void
    private var now = Date()
    private var cancellables: Set<AnyCancellable> = []
    private var timer: AnyCancellable?

    init(
        status: ConversionStatus,
        bookTitle: String,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.status = status
        self.bookTitle = bookTitle
        self.onCancel = onCancel
        self.onRetry = onRetry
        super.init(style: .insetGrouped)
        title = L10n.string("conversionStatus.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("general.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        bind()
    }

    func update(
        status: ConversionStatus,
        bookTitle: String,
        onCancel: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.bookTitle = bookTitle
        self.onCancel = onCancel
        self.onRetry = onRetry
        tableView.reloadData()
    }

    private func bind() {
        status.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &cancellables)

        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
                self?.tableView.reloadSections(IndexSet(integer: 0), with: .none)
            }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        case 1: return max(status.events.count, 1)
        default:
            var count = 0
            if status.lastError != nil { count += 1 }
            if status.startedAt != nil { count += 1 }
            return max(count, 1)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return nil
        case 1: return "Events"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .none

        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                content.text = bookTitle
                content.secondaryText = status.currentChapterName
            } else if indexPath.row == 1 {
                content.text = String(localized: "conversionStatus.preparing")
                content.secondaryText = elapsedLabel
            } else {
                content.text = status.lastError ?? "—"
                content.secondaryText = nil
            }
        case 1:
            if status.events.isEmpty {
                content.text = status.startedAt != nil
                    ? String(localized: "conversionStatus.waitingFirstChunk")
                    : String(localized: "conversionStatus.notStarted")
                content.textProperties.color = .secondaryLabel
            } else {
                let event = status.events[indexPath.row]
                content.text = event.message
                content.secondaryText = formatted(date: event.timestamp)
                content.image = UIImage(systemName: event.kind.systemImage)
            }
        default:
            let actions: [String] = {
                var items: [String] = []
                if status.lastError != nil { items.append(L10n.string("common.retry")) }
                if status.startedAt != nil { items.append(L10n.string("conversionStatus.cancelConversion")) }
                return items
            }()
            if actions.isEmpty {
                content.text = L10n.string("general.done")
            } else {
                content.text = actions[indexPath.row]
                cell.selectionStyle = .default
                cell.accessoryType = .disclosureIndicator
            }
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard indexPath.section == 2 else { return }
        var row = 0
        if status.lastError != nil {
            if indexPath.row == row {
                onRetry()
                dismiss(animated: true)
                return
            }
            row += 1
        }
        if status.startedAt != nil, indexPath.row == row {
            onCancel()
            dismiss(animated: true)
        }
    }

    private var elapsedLabel: String? {
        guard let start = status.startedAt else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0 else { return nil }
        let total = Int(elapsed)
        let m = total / 60
        let s = total % 60
        return L10n.string("conversionStatus.elapsed", String(format: "%d:%02d", m, s))
    }

    private func formatted(date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }
}
#endif
