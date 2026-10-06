import Combine
import Foundation

@MainActor
final class LogsViewModel: ObservableObject {
    @Published var content = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh = true

    private var pollingTask: Task<Void, Never>?

    func start(client: APIClient?, jobId: String) {
        stop()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await fetchOnce(client: client, jobId: jobId)
                if !autoRefresh { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func fetchOnce(client: APIClient?, jobId: String) async {
        guard let client else {
            error = L10n.string("logs.error.noBackend")
            return
        }
        isLoading = true
        error = nil
        do {
            content = try await client.fetchJobLog(id: jobId)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
