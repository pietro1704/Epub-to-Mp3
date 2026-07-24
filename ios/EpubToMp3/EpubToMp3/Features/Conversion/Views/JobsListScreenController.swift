#if os(iOS)
import UIKit

@MainActor
final class JobsListScreenController: UIViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private let controller = JobsListController()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()

    private var sessions: [SessionRecord] = []
    private var fetchTask: Task<Void, Never>?

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer, playbackClock: PlaybackClock) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("jobs.title")
        tabBarItem = UITabBarItem(
            title: L10n.string("nav.conversions"),
            image: UIImage(systemName: "arrow.triangle.2.circlepath"),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(reloadTapped)
        )

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        controller.onSelect = { [weak self] session in
            self?.open(session: session)
        }

        view.addSubview(controller.view)
        view.addSubview(loadingView)
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        controller.didMove(toParent: self)

        applyState(.loading)
        reload()
    }

    deinit {
        fetchTask?.cancel()
    }

    @objc
    private func reloadTapped() {
        reload()
    }

    func refreshFromStores() {
        guard isViewLoaded else { return }
        reload()
    }

    private enum ViewState {
        case loading
        case content
        case message(String)
    }

    private func applyState(_ state: ViewState) {
        switch state {
        case .loading:
            loadingView.startAnimating()
            controller.view.isHidden = true
            messageLabel.isHidden = true
        case .content:
            loadingView.stopAnimating()
            controller.view.isHidden = false
            messageLabel.isHidden = true
        case .message(let text):
            loadingView.stopAnimating()
            controller.view.isHidden = true
            messageLabel.isHidden = false
            messageLabel.text = text
        }
    }

    private func reload() {
        fetchTask?.cancel()
        guard let baseURL = settings.resolvedBaseURL else {
            applyState(.message(L10n.string("jobDetail.error.configureBackend")))
            return
        }
        applyState(.loading)
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = APIClient(baseURL: baseURL)
                let sessions = try await client.fetchSessions()
                guard !Task.isCancelled else { return }
                self.sessions = sessions
                if sessions.isEmpty {
                    self.applyState(.message(L10n.string("jobs.noConversionsDescription")))
                } else {
                    self.controller.apply(sessions: sessions, animated: false)
                    self.applyState(.content)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.applyState(.message(error.localizedDescription))
            }
        }
    }

    private func open(session: SessionRecord) {
        if let jobId = session.jobId, !jobId.isEmpty {
            navigationController?.pushViewController(
                JobDetailScreenController(
                    jobId: jobId,
                    settings: settings,
                    library: library,
                    player: player,
                    playbackClock: playbackClock
                ),
                animated: true
            )
            return
        }
        let alert = UIAlertController(
            title: session.bookTitle,
            message: L10n.string("jobs.historyDetailUnavailable"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert, animated: true)
    }
}
#endif
