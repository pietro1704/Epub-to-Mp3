import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Delegate bridge for URLSession background downloads. iOS owns the task
/// while the app is suspended and relaunches the app to deliver callbacks.
final class AudiobookBackgroundTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = AudiobookBackgroundTransfer()

    private final class Pending: @unchecked Sendable {
        let task: URLSessionDownloadTask
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var result: Result<(URL, URLResponse), Error>?

        init(task: URLSessionDownloadTask) { self.task = task }

        func install(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        @discardableResult
        func finish(_ result: Result<(URL, URLResponse), Error>) -> Bool {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return false }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    private let lock = NSLock()
    private lazy var session = URLSession(
        configuration: AudiobookDownloads.backgroundSessionConfiguration(),
        delegate: self,
        delegateQueue: nil
    )
    private var pending: [Int: Pending] = [:]

    func download(from request: URLRequest) async throws -> (URL, URLResponse) {
        let item = register(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if item.install(continuation) { item.task.resume() }
            }
        } onCancel: {
            self.cancel(item)
        }
    }

    private func register(_ request: URLRequest) -> Pending {
        lock.lock()
        defer { lock.unlock() }
        let task = session.downloadTask(with: request)
        let item = Pending(task: task)
        pending[task.taskIdentifier] = item
        return item
    }

    private func cancel(_ item: Pending) {
        lock.lock()
        pending.removeValue(forKey: item.task.taskIdentifier)
        lock.unlock()
        item.task.cancel()
        item.finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let item = pending.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let item else { return }
        // URLSession deletes its temporary file when this callback returns.
        // Transfer ownership before resuming the asynchronous consumer.
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-download-\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: location, to: stagedURL)
            let accepted = item.finish(.success((
                stagedURL,
                downloadTask.response ?? URLResponse(
                    url: downloadTask.originalRequest?.url ?? URL(string: "about:blank")!,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
            )))
            if !accepted { try? FileManager.default.removeItem(at: stagedURL) }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            item.finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        item?.finish(.failure(error))
    }
}
