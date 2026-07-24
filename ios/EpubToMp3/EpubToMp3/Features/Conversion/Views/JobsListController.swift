#if os(iOS)
import UIKit

@MainActor
final class JobsListController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((SessionRecord) -> Void)?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var sessions: [SessionRecord] = []

    override func loadView() {
        view = tableView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Job")
    }

    func apply(sessions: [SessionRecord], animated: Bool) {
        self.sessions = sessions
        guard isViewLoaded else { return }
        if animated {
            tableView.reloadSections(IndexSet(integer: 0), with: .automatic)
        } else {
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sessions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Job", for: indexPath)
        let row = SessionRowModel.make(from: sessions[indexPath.row])
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.detailText
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        onSelect?(sessions[indexPath.row])
    }
}
#endif
