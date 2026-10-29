#if os(iOS)
import UIKit

/// Each row previews its actual OS-resolved face, including Portuguese glyphs.
@MainActor
final class ReaderFontChoiceController: UITableViewController {
    private let settings: AppSettings
    private let onSelection: () -> Void
    private var choices: [ReaderFontFamily] = []

    init(settings: AppSettings, onSelection: @escaping () -> Void) {
        self.settings = settings
        self.onSelection = onSelection
        super.init(style: .insetGrouped)
        title = L10n.string("settings.font")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        choices = ReaderFontCatalog.choices(retaining: settings.selectedReaderFontFamily)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityIdentifier = "reader.fontCatalog"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let family = choices[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = ReaderFontCatalog.title(for: family)
        content.secondaryText = family == .original ? nil : "Aa Bb Cc — ação, coração, português"
        content.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: ReaderFontCatalog.font(for: family, size: 18))
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "reader.font.\(family.rawValue)"
        cell.accessoryType = settings.selectedReaderFontFamily == family ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let family = choices[indexPath.row]
        guard family.isAvailable(in: ReaderFontCatalog.availableFamilies) else { return }
        settings.readerFontFamily = family
        onSelection()
        tableView.reloadData()
    }
}
#endif
