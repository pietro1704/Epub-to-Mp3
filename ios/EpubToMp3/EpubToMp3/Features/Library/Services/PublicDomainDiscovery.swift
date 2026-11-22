import Foundation

@MainActor
final class PublicDomainDiscovery {
    enum Activity {
        case idle, searching, downloading, importing
    }

    private let catalog: PublicDomainCatalog
    private let importBook: (URL) async throws -> BookEntity
    private var task: Task<Void, Never>?
    private var query = ""
    private var language: PublicDomainCatalog.Language = .all
    private var page = 0

    private(set) var editions: [PublicDomainCatalog.Edition] = []
    private(set) var activity: Activity = .idle
    private(set) var message = ""
    private(set) var hasMore = false
    private(set) var importedBook: BookEntity?
    var onChange: (() -> Void)?

    init(catalog: PublicDomainCatalog = PublicDomainCatalog(),
         importBook: @escaping (URL) async throws -> BookEntity) {
        self.catalog = catalog
        self.importBook = importBook
    }

    deinit { task?.cancel() }

    func search(_ text: String, language: PublicDomainCatalog.Language) {
        guard activity == .idle else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        self.query = query
        self.language = language
        page = 0
        hasMore = false
        editions = []
        loadNextPage()
    }

    func loadNextPage() {
        guard activity == .idle, page == 0 || hasMore, !query.isEmpty else { return }
        start(.searching, messageKey: "discovery.searching")
        task = Task { [weak self, catalog, query, language, page] in
            do {
                let result = try await catalog.search(query: query, language: language, page: page + 1)
                try Task.checkCancellation()
                guard let self else { return }
                self.page = page + 1
                let knownIDs = Set(editions.map(\.id))
                editions.append(contentsOf: result.editions.filter { !knownIDs.contains($0.id) })
                hasMore = result.hasMore
                if result.gutenbergUnavailable {
                    finish("discovery.gutenbergUnavailable")
                } else {
                    finish(editions.isEmpty ? "discovery.noResults" : nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish("discovery.searchFailed")
            }
        }
    }

    func download(_ edition: PublicDomainCatalog.Edition) {
        guard activity == .idle else { return }
        start(.downloading, messageKey: "discovery.downloading")
        task = Task { [weak self, catalog] in
            do {
                let file = try await catalog.download(edition)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                try Task.checkCancellation()
                guard let self else { return }
                activity = .importing
                message = L10n.string("discovery.importing")
                onChange?()
                do {
                    importedBook = try await importBook(file)
                    finish("discovery.imported")
                } catch {
                    finish("discovery.importFailed")
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish("discovery.downloadFailed")
            }
        }
    }

    func cancel() {
        guard activity == .searching || activity == .downloading else { return }
        task?.cancel()
        finish("discovery.cancelled")
    }

    private func start(_ activity: Activity, messageKey: String) {
        self.activity = activity
        message = L10n.string(messageKey)
        importedBook = nil
        onChange?()
    }

    private func finish(_ messageKey: String?) {
        activity = .idle
        task = nil
        message = messageKey.map { L10n.string($0) } ?? ""
        onChange?()
    }
}
