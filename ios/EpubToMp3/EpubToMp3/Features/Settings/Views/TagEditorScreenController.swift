#if os(iOS)
import Combine
import SwiftUI
import UIKit

struct TagEditorScreenHost: UIViewControllerRepresentable {
    let book: BookEntity

    @EnvironmentObject private var library: LibraryStore

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: TagEditorScreenController(book: book, library: library)
        )
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        (controller.viewControllers.first as? TagEditorScreenController)?.update(book: book)
    }
}

@MainActor
final class TagEditorScreenController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case currentTags
        case suggestions
    }

    private let library: LibraryStore
    private var book: BookEntity
    private var cancellables: Set<AnyCancellable> = []

    private let newTagField = UITextField()
    private let addButton = UIButton(type: .system)

    init(book: BookEntity, library: LibraryStore) {
        self.book = book
        self.library = library
        super.init(style: .insetGrouped)
        title = L10n.string("library.editTags")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "TagCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SuggestionCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AddCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("general.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        configureAddControls()
        bindLibrary()
    }

    func update(book: BookEntity) {
        self.book = book
        reloadCurrentBook()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        suggestedTags.isEmpty ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let kind = visibleSections[safe: section] else { return 0 }
        switch kind {
        case .currentTags:
            return book.tags.count + 1
        case .suggestions:
            return suggestedTags.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let kind = visibleSections[safe: section] else { return nil }
        switch kind {
        case .currentTags:
            return L10n.string("tagEditor.tags")
        case .suggestions:
            return L10n.string("tagEditor.existingTags")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = visibleSections[safe: indexPath.section] else {
            return UITableViewCell()
        }
        switch section {
        case .currentTags:
            if indexPath.row == book.tags.count {
                return addCell(for: tableView, at: indexPath)
            }
            return tagCell(for: tableView, at: indexPath)
        case .suggestions:
            return suggestionCell(for: tableView, at: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = visibleSections[safe: indexPath.section] else { return }
        switch section {
        case .currentTags:
            return
        case .suggestions:
            guard suggestedTags.indices.contains(indexPath.row) else { return }
            library.addTag(suggestedTags[indexPath.row], to: book.id)
            reloadCurrentBook()
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard visibleSections[safe: indexPath.section] == .currentTags,
              indexPath.row < book.tags.count else { return nil }
        let tag = book.tags[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.string("common.delete")) { [weak self] _, _, done in
            self?.library.removeTag(tag, from: self?.book.id ?? "")
            self?.reloadCurrentBook()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private var visibleSections: [Section] {
        suggestedTags.isEmpty ? [.currentTags] : [.currentTags, .suggestions]
    }

    private var suggestedTags: [String] {
        library.allTags.filter { !book.tags.contains($0) }
    }

    private func configureAddControls() {
        newTagField.placeholder = L10n.string("tagEditor.newTag")
        newTagField.clearButtonMode = .whileEditing
        newTagField.delegate = self
        newTagField.addTarget(self, action: #selector(newTagChanged), for: .editingChanged)

        var config = UIButton.Configuration.plain()
        config.title = L10n.string("tagEditor.add")
        addButton.configuration = config
        addButton.isEnabled = false
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
    }

    private func bindLibrary() {
        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadCurrentBook()
                }
            }
            .store(in: &cancellables)
    }

    private func reloadCurrentBook() {
        if let refreshed = library.books.first(where: { $0.id == book.id }) {
            book = refreshed
        }
        tableView.reloadData()
    }

    private func tagCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TagCell", for: indexPath)
        let tag = book.tags[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = tag
        content.image = UIImage(systemName: "tag.fill")
        content.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func addCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AddCell", for: indexPath)
        cell.selectionStyle = .none
        if newTagField.superview == nil || addButton.superview == nil {
            let stack = UIStackView(arrangedSubviews: [newTagField, addButton])
            stack.axis = .horizontal
            stack.spacing = 12
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            ])
            addButton.setContentHuggingPriority(.required, for: .horizontal)
        }
        return cell
    }

    private func suggestionCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SuggestionCell", for: indexPath)
        let tag = suggestedTags[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = tag
        content.image = UIImage(systemName: "plus.circle")
        content.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func addCurrentTag() {
        let trimmed = newTagField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        library.addTag(trimmed, to: book.id)
        newTagField.text = ""
        addButton.isEnabled = false
        reloadCurrentBook()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        addCurrentTag()
        textField.resignFirstResponder()
        return true
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }

    @objc
    private func newTagChanged() {
        let trimmed = newTagField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        addButton.isEnabled = !trimmed.isEmpty
    }

    @objc
    private func addTapped() {
        addCurrentTag()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
