#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct BookOpenScreenHost: UIViewControllerRepresentable {
    let book: BookEntity
    var onClose: (() -> Void)?

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var audioWarmup: AudioEngineWarmup

    func makeUIViewController(context: Context) -> BookOpenScreenController {
        BookOpenScreenController(
            book: book,
            onClose: onClose,
            library: library,
            settings: settings,
            player: player,
            audioWarmup: audioWarmup
        )
    }

    func updateUIViewController(_ uiViewController: BookOpenScreenController, context: Context) {
        uiViewController.update(
            book: book,
            onClose: onClose,
            library: library,
            settings: settings,
            player: player,
            audioWarmup: audioWarmup
        )
    }
}

@MainActor
final class BookOpenScreenController: UIViewController, UIDocumentPickerDelegate {
    private var book: BookEntity
    private var onClose: (() -> Void)?
    private var library: LibraryStore
    private var settings: AppSettings
    private var player: AudioPlayer
    private var audioWarmup: AudioEngineWarmup

    private var hostedController: UIHostingController<AnyView>?

    private static let reimportTypes: [UTType] = {
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    init(
        book: BookEntity,
        onClose: (() -> Void)?,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        audioWarmup: AudioEngineWarmup
    ) {
        self.book = book
        self.onClose = onClose
        self.library = library
        self.settings = settings
        self.player = player
        self.audioWarmup = audioWarmup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        mountContentIfNeeded()
    }

    func update(
        book: BookEntity,
        onClose: (() -> Void)?,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        audioWarmup: AudioEngineWarmup
    ) {
        self.book = book
        self.onClose = onClose
        self.library = library
        self.settings = settings
        self.player = player
        self.audioWarmup = audioWarmup
        mountContentIfNeeded()
    }

    private func mountContentIfNeeded() {
        let rootView = AnyView(
            BookOpenContentView(
                book: book,
                onClose: onClose,
                onRequestRePick: { [weak self] in
                    self?.presentRePickPicker()
                }
            )
            .environmentObject(library)
            .environmentObject(settings)
            .environmentObject(player)
            .environmentObject(audioWarmup)
        )

        if let hostedController {
            hostedController.rootView = rootView
            return
        }

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostedController = host
    }

    private func presentRePickPicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.reimportTypes,
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let picked = urls.first else { return }
        do {
            let imported = try library.importBook(from: picked)
            book = imported
            MainReaderView.setCurrentlyReading(bookID: imported.id)
            mountContentIfNeeded()
        } catch {
            presentImportError(error.localizedDescription)
        }
    }

    private func presentImportError(_ message: String) {
        let alert = UIAlertController(
            title: L10n.string("bookOpen.error"),
            message: "Re-import failed: \(message)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert, animated: true)
    }
}
#endif
