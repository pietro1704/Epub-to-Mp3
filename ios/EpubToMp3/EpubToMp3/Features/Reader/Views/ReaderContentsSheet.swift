#if os(iOS)
import UIKit

/// Native sheet listing the book's table of contents (chapter/TOC-entry
/// rows). Presented as a floating modal over the reader — never inline in
/// the reader's own layout — so opening it never pushes or resizes the
/// book's own content. Mirrors `ReaderFootnotesSheet`'s self-contained
/// sheet pattern below.
final class ReaderContentsSheet: UITableViewController {
    private let rows: [ReaderTocRow]
    private let initialChapterIndex: Int
    private let onSelect: (Int) -> Void
    private var hasScrolledToInitialFocus = false

    init(
        rows: [ReaderTocRow],
        initialChapterIndex: Int,
        onSelect: @escaping (Int) -> Void
    ) {
        self.rows = rows
        self.initialChapterIndex = initialChapterIndex
        self.onSelect = onSelect
        super.init(style: .plain)
        title = L10n.string("player.chapters")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "reader.toc"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !hasScrolledToInitialFocus,
              let rowIndex = rows.firstIndex(where: { $0.chapterIndex == initialChapterIndex }) else {
            return
        }
        hasScrolledToInitialFocus = true
        view.layoutIfNeeded()
        tableView.layoutIfNeeded()
        tableView.scrollToRow(
            at: IndexPath(row: rowIndex, section: 0),
            at: .middle,
            animated: false
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter") ?? UITableViewCell(style: .default, reuseIdentifier: "chapter")
        let row = rows[indexPath.row]
        let isFocused = row.chapterIndex == initialChapterIndex
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.chapterIndex.map { L10n.string("reader.chapter", $0 + 1) }
        content.textProperties.font = .preferredFont(forTextStyle: isFocused ? .headline : .body)
        content.textProperties.color = isFocused ? view.tintColor : .label
        content.secondaryTextProperties.color = isFocused ? view.tintColor : .secondaryLabel
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = isFocused ? view.tintColor.withAlphaComponent(0.12) : .clear
        cell.backgroundConfiguration = background
        cell.indentationLevel = row.level
        cell.accessibilityTraits = isFocused ? [.button, .selected] : .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let chapterIndex = rows[indexPath.row].chapterIndex else { return }
        onSelect(chapterIndex)
        dismiss(animated: true)
    }
}

#endif
