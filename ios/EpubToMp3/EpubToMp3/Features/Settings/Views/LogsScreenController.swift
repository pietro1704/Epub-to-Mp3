#if os(iOS)
import Combine
import SwiftUI
import UIKit

@MainActor
final class LogsScreenController: UIViewController {
    private let settings: AppSettings
    private let jobId: String
    private let viewModel = LogsViewModel()
    private var cancellables: Set<AnyCancellable> = []

    private let textView = UITextView()
    private let emptyLabel = UILabel()
    private let errorLabel = UILabel()

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    init(settings: AppSettings, jobId: String) {
        self.settings = settings
        self.jobId = jobId
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("jobDetail.openLogs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureUI()
        bindViewModel()
        viewModel.start(client: client, jobId: jobId)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.topViewController !== self {
            viewModel.stop()
        }
    }

    private func configureUI() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "pause.circle"),
            style: .plain,
            target: self,
            action: #selector(toggleAutoRefresh)
        )

        textView.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        textView.textColor = .systemGreen
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = L10n.string("logs.empty")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .white
        errorLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.numberOfLines = 0
        errorLabel.layer.cornerRadius = 8
        errorLabel.layer.masksToBounds = true
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        view.addSubview(emptyLabel)
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    private func bindViewModel() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.render()
                }
            }
            .store(in: &cancellables)
    }

    private func render() {
        textView.text = viewModel.content
        emptyLabel.isHidden = !viewModel.content.isEmpty || viewModel.isLoading
        errorLabel.isHidden = viewModel.error == nil
        errorLabel.text = viewModel.error.map { "  \($0)  " }
        let icon = viewModel.autoRefresh ? "pause.circle" : "play.circle"
        navigationItem.rightBarButtonItem?.image = UIImage(systemName: icon)
        navigationItem.rightBarButtonItem?.accessibilityLabel = viewModel.autoRefresh
            ? L10n.string("logs.pauseAutoRefresh")
            : L10n.string("logs.resumeAutoRefresh")
        if viewModel.autoRefresh && !viewModel.content.isEmpty {
            let bottom = NSRange(location: max(0, textView.text.count - 1), length: 1)
            textView.scrollRangeToVisible(bottom)
        }
    }

    @objc
    private func toggleAutoRefresh() {
        viewModel.autoRefresh.toggle()
        if viewModel.autoRefresh {
            viewModel.start(client: client, jobId: jobId)
        } else {
            viewModel.stop()
        }
        render()
    }
}
#endif
