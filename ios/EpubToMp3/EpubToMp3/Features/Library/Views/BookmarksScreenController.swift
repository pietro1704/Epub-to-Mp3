#if os(iOS)
import Combine
import UIKit

@MainActor
final class BookmarksScreenController: UITableViewController {
    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    enum Filter: Int, CaseIterable {
        case all
        case bookmarks
        case highlights

        var title: String {
            switch self {
            case .all:
                return L10n.string("bookmarks.filter.all")
            case .bookmarks:
                return L10n.string("bookmarks.filter.bookmarks")
            case .highlights:
                return L10n.string("bookmarks.filter.highlights")
            }
        }
    }

    private var bookId: String
    private let bookmarkStore: BookmarkStore
    private var onJumpToChapter: ((Int) -> Void)?
    private var filter: Filter = .all
    private var cancellables: Set<AnyCancellable> = []
    private let filterControl = UISegmentedControl()
    private let emptyStateLabel = UILabel()

    init(
        bookId: String,
        bookmarkStore: BookmarkStore,
        onJumpToChapter: ((Int) -> Void)?
    ) {
        self.bookId = bookId
        self.bookmarkStore = bookmarkStore
        self.onJumpToChapter = onJumpToChapter
        super.init(style: .plain)
        title = L10n.string("player.bookmarks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BookmarkCell")
        configureNavigation()
        configureEmptyState()
        bindStore()
        reloadData()
    }

    func update(bookId: String, onJumpToChapter: ((Int) -> Void)?) {
        self.bookId = bookId
        self.onJumpToChapter = onJumpToChapter
        reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredBookmarks.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BookmarkCell", for: indexPath)
        let bookmark = filteredBookmarks[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = bookmark.chapterTitle
        content.textProperties.numberOfLines = 2

        var secondaryLines: [String] = []
        if bookmark.isHighlight {
            secondaryLines.append(bookmark.selectedText)
        }
        if let note = bookmark.note, !note.isEmpty {
            secondaryLines.append(note)
        }
        secondaryLines.append(Self.relativeDateFormatter.localizedString(for: bookmark.createdAt, relativeTo: Date()))
        content.secondaryText = secondaryLines.joined(separator: "\n")
        content.secondaryTextProperties.numberOfLines = 4
        content.image = UIImage(systemName: bookmark.isHighlight ? "highlighter" : "bookmark.fill")
        content.imageProperties.tintColor = bookmark.isHighlight ? bookmark.color.uiColor : .systemOrange
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard filteredBookmarks.indices.contains(indexPath.row) else { return }
        onJumpToChapter?(filteredBookmarks[indexPath.row].chapterIndex)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard filteredBookmarks.indices.contains(indexPath.row) else { return nil }
        let bookmark = filteredBookmarks[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.string("common.delete")) { [weak self] _, _, done in
            self?.bookmarkStore.remove(id: bookmark.id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard filteredBookmarks.indices.contains(indexPath.row) else { return nil }
        let bookmark = filteredBookmarks[indexPath.row]
        let edit = UIContextualAction(style: .normal, title: L10n.string("bookmarks.note")) { [weak self] _, _, done in
            self?.presentEditor(for: bookmark)
            done(true)
        }
        edit.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [edit])
    }

    private var filteredBookmarks: [Bookmark] {
        let all = bookmarkStore.bookmarks(for: bookId)
        switch filter {
        case .all:
            return all
        case .bookmarks:
            return all.filter { !$0.isHighlight }
        case .highlights:
            return all.filter { $0.isHighlight }
        }
    }

    private func configureNavigation() {
        filterControl.removeAllSegments()
        for (index, filter) in Filter.allCases.enumerated() {
            filterControl.insertSegment(withTitle: filter.title, at: index, animated: false)
        }
        filterControl.selectedSegmentIndex = filter.rawValue
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("general.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 52))
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(filterControl)
        NSLayoutConstraint.activate([
            filterControl.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            filterControl.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
            filterControl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        tableView.tableHeaderView = container
    }

    private func configureEmptyState() {
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.text = [
            L10n.string("bookmarks.emptyTitle"),
            "",
            L10n.string("bookmarks.emptyDescription"),
        ].joined(separator: "\n")
    }

    private func bindStore() {
        bookmarkStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadData()
            }
            .store(in: &cancellables)
    }

    private func reloadData() {
        tableView.reloadData()
        tableView.backgroundView = filteredBookmarks.isEmpty ? emptyStateLabel : nil
        tableView.separatorStyle = filteredBookmarks.isEmpty ? .none : .singleLine
    }

    private func presentEditor(for bookmark: Bookmark) {
        let controller = BookmarkNoteEditorController(bookmark: bookmark, bookmarkStore: bookmarkStore)
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    @objc
    private func filterChanged() {
        filter = Filter(rawValue: filterControl.selectedSegmentIndex) ?? .all
        reloadData()
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }
}

@MainActor
private final class BookmarkNoteEditorController: UIViewController {
    private let bookmark: Bookmark
    private let bookmarkStore: BookmarkStore
    private var selectedColor: HighlightColor

    private let textView = UITextView()
    private let highlightedTextLabel = UILabel()
    private let colorStack = UIStackView()

    init(bookmark: Bookmark, bookmarkStore: BookmarkStore) {
        self.bookmark = bookmark
        self.bookmarkStore = bookmarkStore
        self.selectedColor = bookmark.color
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("bookmarks.editNote")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("general.cancel"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("common.save"),
            style: .done,
            target: self,
            action: #selector(saveTapped)
        )
        buildUI()
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let noteTitle = makeSectionTitle(L10n.string("bookmarks.note"))
        textView.text = bookmark.note ?? ""
        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(noteTitle)
        stack.addArrangedSubview(textView)
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        if bookmark.isHighlight {
            let highlightedTitle = makeSectionTitle(L10n.string("bookmarks.highlightedText"))
            highlightedTextLabel.text = bookmark.selectedText
            highlightedTextLabel.numberOfLines = 0
            highlightedTextLabel.textColor = .secondaryLabel

            let colorTitle = makeSectionTitle(L10n.string("bookmarks.color"))
            colorStack.axis = .horizontal
            colorStack.spacing = 12
            colorStack.alignment = .center
            HighlightColor.allCases.forEach { color in
                colorStack.addArrangedSubview(makeColorButton(color))
            }

            stack.addArrangedSubview(highlightedTitle)
            stack.addArrangedSubview(highlightedTextLabel)
            stack.addArrangedSubview(colorTitle)
            stack.addArrangedSubview(colorStack)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
        ])
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = text
        return label
    }

    private func makeColorButton(_ color: HighlightColor) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.tag = HighlightColor.allCases.firstIndex(of: color) ?? 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.layer.cornerRadius = 18
        button.layer.borderWidth = color == selectedColor ? 3 : 1
        button.layer.borderColor = color == selectedColor ? UIColor.label.cgColor : UIColor.separator.cgColor
        button.backgroundColor = color.uiColor
        button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc
    private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc
    private func saveTapped() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarkStore.updateNote(id: bookmark.id, note: trimmed.isEmpty ? nil : trimmed)
        if bookmark.isHighlight {
            bookmarkStore.updateColor(id: bookmark.id, color: selectedColor)
        }
        dismiss(animated: true)
    }

    @objc
    private func colorTapped(_ sender: UIButton) {
        guard HighlightColor.allCases.indices.contains(sender.tag) else { return }
        selectedColor = HighlightColor.allCases[sender.tag]
        for case let button as UIButton in colorStack.arrangedSubviews {
            let isSelected = button.tag == sender.tag
            button.layer.borderWidth = isSelected ? 3 : 1
            button.layer.borderColor = isSelected ? UIColor.label.cgColor : UIColor.separator.cgColor
        }
    }
}

private extension HighlightColor {
    var uiColor: UIColor {
        switch self {
        case .yellow:
            return .systemYellow
        case .blue:
            return .systemBlue
        case .green:
            return .systemGreen
        case .pink:
            return .systemPink
        case .orange:
            return .systemOrange
        }
    }
}
#endif
