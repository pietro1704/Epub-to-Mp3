import Combine
import Foundation

#if os(iOS)
@MainActor
final class JobDetailViewModel: ObservableObject {
    @Published private(set) var snapshot: JobSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestPayload = ""
    @Published private(set) var receivedCount = 0
    @Published private(set) var isStreaming = false
    @Published private(set) var downloadState: DownloadProgress.State?
    @Published private(set) var downloadProgressLabel: String?

    /// Delivers every decoded snapshot to the owning screen so a player that
    /// is already attached to this job can append newly completed chapters
    /// without coupling this view model to UIKit or AppKit.
    var onSnapshot: ((JobSnapshot) -> Void)?

    private var streamTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    func start(client: APIClient?, jobId: String) {
        stop()
        guard let client else {
            errorMessage = APIError.invalidBaseURL.localizedDescription
            return
        }
        streamTask = Task { [weak self] in
            do {
                let initial = try await client.fetchJob(id: jobId)
                guard let self, !Task.isCancelled else { return }
                self.snapshot = initial
                self.onSnapshot?(initial)
                self.errorMessage = nil
                self.isStreaming = true
                for try await event in client.eventStream(jobId: jobId) {
                    guard !Task.isCancelled else { return }
                    self.receivedCount += 1
                    self.latestPayload = event.rawPayload
                    if let next = APIClient.decodeSnapshot(from: event.rawPayload) {
                        self.snapshot = next
                        self.onSnapshot?(next)
                        if next.isTerminal { self.isStreaming = false }
                    }
                }
                self.isStreaming = false
            } catch {
                guard !Task.isCancelled, let strongSelf = self else { return }
                strongSelf.errorMessage = error.localizedDescription
                strongSelf.isStreaming = false
            }
        }
        progressTask = Task { [weak self] in
            for await progress in await DownloadManager.shared.watchProgress(jobId: jobId) {
                guard let self, !Task.isCancelled else { return }
                self.downloadState = progress.state
                self.downloadProgressLabel = progress.totalChapters > 0
                    ? "\(progress.completedChapters)/\(progress.totalChapters)"
                    : nil
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        progressTask?.cancel()
        streamTask = nil
        progressTask = nil
        isStreaming = false
    }

    func downloadAll(baseURL: URL?) {
        guard let snapshot else { return }
        Task { await DownloadManager.shared.enqueueAll(snapshot: snapshot, baseURL: baseURL) }
    }

    func cancelDownloads() {
        guard let jobId = snapshot?.jobId else { return }
        Task { await DownloadManager.shared.cancel(jobId: jobId) }
    }

    func clearDownloads() {
        guard let jobId = snapshot?.jobId else { return }
        Task { await DownloadManager.shared.clearDownloadedBook(jobId: jobId) }
    }
}
#endif
