#if os(iOS)
import UIKit

/// Owns one book-scoped search request; the viewport owns revealing a result.
@MainActor
final class ReaderSearchPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let persist: () -> Void
    private let showChapter: (Int) -> Void
    private let present: (UIViewController) -> Void
    private let isCurrentBook: () -> Bool
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private weak var prompt: UIAlertController?

    init(document: ReaderBookDocument, composition: ReaderViewComposition,
         persist: @escaping () -> Void, showChapter: @escaping (Int) -> Void,
         present: @escaping (UIViewController) -> Void, isCurrentBook: @escaping () -> Bool) {
        self.document = document
        self.composition = composition
        self.persist = persist
        self.showChapter = showChapter
        self.present = present
        self.isCurrentBook = isCurrentBook
    }

    deinit { task?.cancel() }

    func cancel() {
        cancelQuery()
        prompt?.dismiss(animated: false)
        prompt = nil
    }

    private func cancelQuery() {
        requestID = UUID()
        task?.cancel()
    }

    func waitForCompletion() async { await task?.value }

    func promptSearch() {
        guard isCurrentBook(), prompt == nil else { return }
        cancel()
        guard composition.contentSurface.kind == .text else {
            showMessage("reader.search.unavailable")
            return
        }
        let alert = UIAlertController(title: L10n.string("reader.search.placeholder"),
            message: document.fulltext == nil ? L10n.string("reader.search.currentChapter") : nil,
            preferredStyle: .alert)
        alert.addTextField {
            $0.returnKeyType = .search
            $0.autocapitalizationType = .none
            $0.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { [weak self] _ in
            self?.cancelQuery()
            self?.prompt = nil
        })
        let action = UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self, weak alert] _ in
            guard let query = alert?.textFields?.first?.text else { return }
            alert?.dismiss(animated: true) { [weak self] in
                self?.prompt = nil
                self?.performSearch(query: query)
            }
        }
        action.isEnabled = false
        alert.addAction(action)
        alert.preferredAction = action
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak action, weak field] _ in
                action?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, for: .editingChanged)
        }
        prompt = alert
        present(alert)
    }

    func performSearch(query: String) {
        cancelQuery()
        guard isCurrentBook(), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard composition.contentSurface.kind == .text else { showMessage("reader.search.unavailable"); return }
        let request = requestID
        let generation = document.loadGenerationID
        let origin = document.selectedChapter
        let originOffset = composition.scrollView.contentOffset
        var chapters = document.fulltext?.chapters.enumerated().map {
            ReaderBookSearch.Chapter(position: $0.offset, text: $0.element.text)
        } ?? []
        let displayed = composition.textView.attributedText?.string ?? ""
        if let index = chapters.firstIndex(where: { $0.position == origin }) {
            chapters[index] = .init(position: origin, text: displayed)
        } else if !displayed.isEmpty {
            chapters = [.init(position: origin, text: displayed)]
        }
        let sources = chapters
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                ReaderBookSearch.candidates(query: query, chapters: sources, startingAt: origin,
                    isCancelled: { Task.isCancelled })
            }
            let candidates = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, requestID == request, isCurrentBook(),
                  document.loadGenerationID == generation, document.selectedChapter == origin else { return }
            for chapter in candidates {
                if chapter != document.selectedChapter {
                    document.selectedChapter = chapter
                    showChapter(chapter)
                }
                composition.view.layoutIfNeeded()
                guard let range = ReaderBookSearch.firstRange(query: query, in: composition.textView.attributedText?.string ?? ""),
                      composition.textViewport.reveal(range) else { continue }
                persist()
                return
            }
            if document.selectedChapter != origin {
                document.selectedChapter = origin
                showChapter(origin)
                composition.view.layoutIfNeeded()
                composition.scrollView.setContentOffset(originOffset, animated: false)
            }
            showMessage("reader.search.noResults")
        }
    }

    private func showMessage(_ key: String) {
        let alert = UIAlertController(title: L10n.string("reader.search"), message: L10n.string(key), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert)
    }
}
#endif
