#if os(iOS)
import UIKit

@MainActor
final class PublicDomainViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let discovery: PublicDomainDiscovery
    private let onOpen: (BookEntity) -> Void
    private let searchBar = UISearchBar()
    private let language = UISegmentedControl(items: PublicDomainCatalog.Language.allCases.map(\.label))
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = UILabel()
    private let more = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let open = UIButton(type: .system)

    init(discovery: PublicDomainDiscovery, onOpen: @escaping (BookEntity) -> Void) {
        self.discovery = discovery
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("discovery.title")
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self,
                                                            action: #selector(close))
        searchBar.placeholder = L10n.string("discovery.search")
        searchBar.accessibilityIdentifier = "discovery.search"
        searchBar.delegate = self
        language.selectedSegmentIndex = 0
        language.accessibilityLabel = L10n.string("discovery.language")
        language.addTarget(self, action: #selector(search), for: .valueChanged)
        let rights = UILabel()
        rights.text = L10n.string("discovery.gutenbergRights")
        rights.numberOfLines = 0
        rights.font = .preferredFont(forTextStyle: .footnote)
        rights.adjustsFontForContentSizeCategory = true
        let brazil = UIButton(type: .system)
        configure(brazil, "discovery.brazilCatalog", #selector(openBrazil))
        configure(more, "discovery.more", #selector(loadMore))
        configure(cancel, "library.cancel", #selector(cancelTask))
        configure(open, "library.openBook", #selector(openImported))
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.accessibilityIdentifier = "discovery.status"
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        let stack = UIStackView(arrangedSubviews: [rights, brazil, language, searchBar, table,
                                                   status, more, cancel, open])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            table.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        discovery.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func configure(_ button: UIButton, _ label: String, _ action: Selector) {
        button.setTitle(L10n.string(label), for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func refresh() {
        let idle = discovery.activity == .idle
        searchBar.isUserInteractionEnabled = idle
        language.isEnabled = idle
        table.allowsSelection = idle
        more.isHidden = !idle || !discovery.hasMore
        cancel.isHidden = idle || discovery.activity == .importing
        open.isHidden = discovery.importedBook == nil
        status.text = discovery.message
        status.isHidden = discovery.message.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = discovery.activity != .importing
        table.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { search() }

    @objc private func search() {
        searchBar.resignFirstResponder()
        discovery.search(searchBar.text ?? "", language: PublicDomainCatalog.Language.allCases[language.selectedSegmentIndex])
    }

    @objc private func loadMore() { discovery.loadNextPage() }
    @objc private func cancelTask() { discovery.cancel() }

    @objc private func openBrazil() {
        UIApplication.shared.open(PublicDomainCatalog.brazilianCatalog)
    }

    @objc private func close() {
        discovery.cancel()
        dismiss(animated: true)
    }

    @objc private func openImported() {
        guard let book = discovery.importedBook else { return }
        dismiss(animated: true) { [onOpen] in onOpen(book) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        discovery.editions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "edition")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "edition")
        var content = cell.defaultContentConfiguration()
        let edition = discovery.editions[indexPath.row]
        content.text = edition.title
        content.secondaryText = resultDetails(edition)
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func resultDetails(_ edition: PublicDomainCatalog.Edition) -> String {
        [edition.detail, edition.attribution].joined(separator: "\n")
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let edition = discovery.editions[indexPath.row]
        let alert = UIAlertController(title: edition.title, message: resultDetails(edition), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("discovery.download"), style: .default) { [weak self] _ in
            self?.discovery.download(edition)
        })
        alert.addAction(UIAlertAction(title: L10n.string("discovery.source"), style: .default) { _ in
            UIApplication.shared.open(edition.source)
        })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
#endif
