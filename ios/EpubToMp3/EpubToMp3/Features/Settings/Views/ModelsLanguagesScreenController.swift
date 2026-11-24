#if os(iOS)
import UIKit

/// The language list of the Models screen, pushed from it: the system languages first, then the most popular ones,
/// then every other language alphabetically (CONTEXT.md, "Models screen language order").
@MainActor
final class ModelsLanguagesScreenController: UITableViewController {
    private struct Group { let title: String; let tags: [String] }

    private let groups: [Group]
    private let counts: [String: Int]
    private let uiLocale: Locale
    private let onSelect: (String) -> Void

    init(languages: [CatalogLanguage], systemPreferred: [String] = Locale.preferredLanguages,
         uiLocale: Locale = .current, onSelect: @escaping (String) -> Void) {
        let order = ModelLanguageOrder.sections(languages: languages, systemPreferred: systemPreferred, uiLocale: uiLocale)
        groups = [Group(title: L10n.string("models.languages.system"), tags: order.system),
                  Group(title: L10n.string("models.languages.popular"), tags: order.popular),
                  Group(title: L10n.string("models.languages.all"), tags: order.others)].filter { !$0.tags.isEmpty }
        counts = Dictionary(languages.map { ($0.tag, $0.modelCount) }, uniquingKeysWith: { first, _ in first })
        self.uiLocale = uiLocale
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        title = L10n.string("models.languages")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Language")
        tableView.accessibilityIdentifier = "models.languages.table"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].tags.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].title }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let tag = groups[indexPath.section].tags[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Language", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let name = ModelLanguageOrder.displayName(tag, in: uiLocale)
        content.text = name.prefix(1).uppercased() + name.dropFirst()
        content.secondaryText = ModelLanguageOrder.modelCountText(counts[tag] ?? 0)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "models.languages.row.\(tag)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(groups[indexPath.section].tags[indexPath.row])
    }
}
#endif
