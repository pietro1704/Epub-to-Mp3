#if os(iOS)
import UIKit

@MainActor
final class ReaderLinkPreviewController: UIViewController, UITextViewDelegate {
    let textView = UITextView()
    private let body: NSAttributedString
    private let navigate: (() -> Void)?
    private var didNavigate = false

    init(title: String, body: NSAttributedString, navigate: (() -> Void)?) {
        self.body = body
        self.navigate = navigate
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        textView.attributedText = body
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.accessibilityIdentifier = "reader.linkPreview.text"
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
            target: self, action: #selector(close))
        if navigate != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L10n.string("reader.link.goToPosition"),
                style: .plain, target: self, action: #selector(goToPosition))
            navigationItem.rightBarButtonItem?.accessibilityIdentifier = "reader.linkPreview.goToPosition"
        }
    }

    @objc func close() {
        didNavigate = true
        dismiss(animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.presentingViewController == nil { didNavigate = true }
    }

    @objc func goToPosition() {
        guard let navigate, !didNavigate else { return }
        didNavigate = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        if presentingViewController == nil { navigate() } else { dismiss(animated: true, completion: navigate) }
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        ["https", "http", "mailto", "tel"].contains(URL.scheme?.lowercased() ?? "")
    }
}
#endif
