#if os(iOS)
import UIKit

/// Native sheet listing a chapter's footnotes as `{number, text}` pairs.
/// Deliberately does not try to resolve a tap-to-jump from an inline
/// reference — `raw_html` may point at a separate notes document the
/// sanitizer doesn't preserve cross-document, so a plain listing is the
/// robust choice (see `docs/reader-spec-comparison.md` P0 gap #1 notes).
final class ReaderFootnotesSheet: UITableViewController {
    private let footnotes: [EbookFulltext.Footnote]

    init(footnotes: [EbookFulltext.Footnote]) {
        self.footnotes = footnotes
        super.init(style: .plain)
        title = L10n.string("reader.footnotes.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { footnotes.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "footnote") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "footnote")
        let footnote = footnotes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = footnote.number.map { "#\($0)" } ?? "#\(indexPath.row + 1)"
        content.secondaryText = footnote.text
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }
}

#endif
