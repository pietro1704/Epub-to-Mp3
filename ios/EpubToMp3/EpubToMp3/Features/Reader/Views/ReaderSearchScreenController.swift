#if os(iOS)
import SwiftUI
import UIKit

struct ReaderSearchScreenHost: UIViewControllerRepresentable {
    let chapters: [EbookFulltext.Chapter]
    var onJumpToChapter: ((Int) -> Void)?
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = ReaderSearchScreenController(
            chapters: chapters,
            onJumpToChapter: onJumpToChapter,
            onDismiss: { isPresented = false }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        guard let root = controller.viewControllers.first as? ReaderSearchScreenController else { return }
        root.update(chapters: chapters, onJumpToChapter: onJumpToChapter, onDismiss: { isPresented = false })
    }
}

@MainActor
final class ReaderSearchScreenController: UITableViewController, UISearchResultsUpdating {
    private var chapters: [EbookFulltext.Chapter]
    private var onJumpToChapter: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    private var results: [SearchResult] = []
    private var query = ""

    init(
        chapters: [EbookFulltext.Chapter],
        onJumpToChapter: ((Int) -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        self.chapters = chapters
        self.onJumpToChapter = onJumpToChapter
        self.onDismiss = onDismiss
        super.init(style: .plain)
        title = L10n.string("instantReader.searchInBook")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = L10n.string("instantReader.searchInBook")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("general.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    func update(
        chapters: [EbookFulltext.Chapter],
        onJumpToChapter: ((Int) -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        self.chapters = chapters
        self.onJumpToChapter = onJumpToChapter
        self.onDismiss = onDismiss
        if isViewLoaded {
            search()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        search()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.isEmpty && !query.isEmpty ? 1 : results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if results.isEmpty && !query.isEmpty {
            content.text = String(localized: "search.noResults")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
            cell.contentConfiguration = content
            return cell
        }

        let result = results[indexPath.row]
        content.text = result.chapterTitle
        content.secondaryText = result.snippet
        content.secondaryTextProperties.numberOfLines = 3
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard results.indices.contains(indexPath.row) else { return }
        onJumpToChapter?(results[indexPath.row].chapterIndex)
        onDismiss?()
    }

    @objc
    private func doneTapped() {
        onDismiss?()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        let lowered = q.lowercased()
        var found: [SearchResult] = []
        for chapter in chapters {
            let text = chapter.text
            let lower = text.lowercased()
            var searchStart = lower.startIndex
            while let range = lower.range(of: lowered, range: searchStart..<lower.endIndex) {
                let snippetStart = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let snippetEnd = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = "…" + text[snippetStart..<snippetEnd].replacingOccurrences(of: "\n", with: " ") + "…"
                found.append(SearchResult(
                    chapterIndex: chapter.index,
                    chapterTitle: chapter.displayTitle,
                    snippet: snippet,
                    range: range
                ))
                searchStart = range.upperBound
                if found.count >= 100 { break }
            }
            if found.count >= 100 { break }
        }
        results = found
        tableView.reloadData()
    }
}
#endif
