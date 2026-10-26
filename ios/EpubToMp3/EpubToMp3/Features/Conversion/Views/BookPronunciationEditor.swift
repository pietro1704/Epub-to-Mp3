#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum BookPronunciationEditor {
    #if os(macOS)
    static func present(bookID: String, on controller: NSViewController,
                        store: BookPronunciationStore = BookPronunciationStore()) {
        let alert = NSAlert()
        alert.messageText = L10n.string("pronunciation.title")
        alert.informativeText = L10n.string("pronunciation.instructions")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.string = store.load(bookID: bookID).editableText
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.string("pronunciation.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.save(BookPronunciationDictionary.parse(editor.string), bookID: bookID) }
        catch {
            let failure = NSAlert()
            failure.messageText = L10n.string("pronunciation.invalid")
            failure.runModal()
        }
    }
    #else
    static func present(bookID: String, on controller: UIViewController,
                        store: BookPronunciationStore = BookPronunciationStore()) {
        controller.present(PronunciationEditorController(bookID: bookID, store: store), animated: true)
    }
    #endif
}

#if os(iOS)
@MainActor
private final class PronunciationEditorController: UIViewController {
    private let bookID: String
    private let store: BookPronunciationStore
    private let editor = UITextView()
    private let errorLabel = UILabel()
    init(bookID: String, store: BookPronunciationStore) {
        self.bookID = bookID
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let instructions = UILabel()
        instructions.text = L10n.string("pronunciation.instructions")
        instructions.numberOfLines = 0
        instructions.font = .preferredFont(forTextStyle: .body)
        instructions.adjustsFontForContentSizeCategory = true
        editor.text = store.load(bookID: bookID).editableText
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.autocorrectionType = .no
        editor.smartQuotesType = .no
        editor.accessibilityIdentifier = "pronunciation.editor"
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed
        let save = UIButton(type: .system)
        save.setTitle(L10n.string("pronunciation.save"), for: .normal)
        save.addTarget(self, action: #selector(saveRules), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle(L10n.string("common.cancel"), for: .normal)
        cancel.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [instructions, editor, errorLabel, save, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            editor.heightAnchor.constraint(equalToConstant: 220),
            save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
    @objc private func saveRules() {
        do {
            try store.save(BookPronunciationDictionary.parse(editor.text), bookID: bookID)
            dismiss(animated: true)
        } catch { errorLabel.text = L10n.string("pronunciation.invalid") }
    }
    @objc private func cancelEditing() { dismiss(animated: true) }
}
#endif
