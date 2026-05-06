import Foundation

/// Disk-cached fetcher for `/api/jobs/{id}/fulltext`.
///
/// Behaviour:
///   - On `load(jobId:)` first surfaces any on-disk copy (so the reader
///     opens instantly offline), then races the network and overwrites
///     the cache when the live response is newer / non-empty.
///   - Retries 503 responses with the back-off ladder pinned in memory
///     `project_reader_fulltext.md`: [800, 1500, 3000, 6000, 12000] ms.
///   - 404 / 422 are surfaced as permanent errors — no retry.
///   - Persists JSON to `<documents>/Audiobooks/<jobId>/fulltext.json`,
///     reusing the layout established by `DownloadManager`.
final class FulltextStore: @unchecked Sendable {

    enum FulltextError: LocalizedError, Equatable {
        case offlineUnavailable          // No disk copy and no network success.
        case gone                         // 404 — job gone.
        case emptyParse                   // 422 — parsed cleanly, zero chapters.
        case transientExhausted(String)   // 503 ran out of retry budget.
        case http(status: Int, body: String)
        case decoding(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .offlineUnavailable: return "Reader text not available offline yet."
            case .gone: return "This book is no longer available on the backend."
            case .emptyParse: return "We couldn't extract any chapter text from this book."
            case .transientExhausted(let detail):
                return "Backend is still extracting text. Try again shortly. (\(detail))"
            case .http(let status, let body):
                return "Server responded with HTTP \(status). \(body.prefix(200))"
            case .decoding(let msg): return "Failed to decode reader payload: \(msg)"
            case .transport(let msg): return "Network error: \(msg)"
            }
        }
    }

    /// Retry ladder enforced verbatim by the contract memory.
    static let retryLadderMs: [Int] = [800, 1500, 3000, 6000, 12000]

    /// Storage layout shared with `DownloadManager` so a single
    /// audiobook folder owns both audio and reader text.
    static func fulltextURL(for jobId: String) -> URL {
        let base = DownloadManager.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fulltext.json")
    }

    static func loadFromDisk(jobId: String) -> EbookFulltext? {
        guard let data = try? Data(contentsOf: fulltextURL(for: jobId)) else { return nil }
        return try? JSONDecoder().decode(EbookFulltext.self, from: data)
    }

    static func saveToDisk(_ payload: EbookFulltext) throws {
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fulltextURL(for: payload.jobId), options: .atomic)
    }

    // MARK: AsyncStream API

    private let lock = NSLock()
    private var continuations: [String: [UUID: AsyncStream<EbookFulltext>.Continuation]] = [:]
    private var lastValue: [String: EbookFulltext] = [:]

    /// Subscribe to fulltext payloads for a job. Yields any on-disk copy
    /// immediately, then any subsequent network refresh. Cancelling the
    /// iterator removes the subscription.
    func watch(jobId: String) -> AsyncStream<EbookFulltext> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.continuations[jobId, default: [:]][id] = continuation
            if let last = self.lastValue[jobId] { continuation.yield(last) }
            else if let disk = Self.loadFromDisk(jobId: jobId) {
                self.lastValue[jobId] = disk
                continuation.yield(disk)
            }
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[jobId]?.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    private func emit(_ payload: EbookFulltext) {
        lock.lock()
        lastValue[payload.jobId] = payload
        let conts = continuations[payload.jobId]?.values ?? [:].values
        lock.unlock()
        for cont in conts { cont.yield(payload) }
    }

    // MARK: Network

    /// Fetch `/api/jobs/{id}/fulltext` with the documented retry ladder.
    /// On success, persists to disk AND emits to all `watch()`
    /// subscribers. Throws `FulltextError` on permanent failure.
    @discardableResult
    func refresh(
        jobId: String,
        baseURL: URL,
        urlSession: URLSession = .shared
    ) async throws -> EbookFulltext {
        let url = baseURL.appendingPathComponent("api/jobs/\(jobId)/fulltext")
        var lastTransientDetail = ""

        for attempt in 0...Self.retryLadderMs.count {
            do {
                let (data, response) = try await urlSession.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw FulltextError.transport("non-HTTP response")
                }
                switch http.statusCode {
                case 200:
                    do {
                        let payload = try JSONDecoder().decode(EbookFulltext.self, from: data)
                        try? Self.saveToDisk(payload)
                        emit(payload)
                        return payload
                    } catch {
                        throw FulltextError.decoding(String(describing: error))
                    }
                case 404:
                    throw FulltextError.gone
                case 422:
                    throw FulltextError.emptyParse
                case 503:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    lastTransientDetail = body.prefix(120).description
                    if attempt >= Self.retryLadderMs.count {
                        throw FulltextError.transientExhausted(lastTransientDetail)
                    }
                    let delayMs = Self.retryLadderMs[attempt]
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    continue
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw FulltextError.http(status: http.statusCode, body: body)
                }
            } catch let err as FulltextError {
                throw err
            } catch {
                // Transport-level failure — treat as transient until
                // ladder is exhausted, mirroring the web client's
                // behaviour in EbookReaderPanel.
                lastTransientDetail = error.localizedDescription
                if attempt >= Self.retryLadderMs.count {
                    throw FulltextError.transport(lastTransientDetail)
                }
                let delayMs = Self.retryLadderMs[attempt]
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                continue
            }
        }
        throw FulltextError.transientExhausted(lastTransientDetail)
    }

    /// Convenience wrapper used by views: surface any on-disk copy
    /// synchronously (so the reader renders immediately), then trigger
    /// a network refresh in the background.
    func loadAndRefresh(
        jobId: String,
        baseURL: URL?,
        urlSession: URLSession = .shared
    ) -> EbookFulltext? {
        let cached = Self.loadFromDisk(jobId: jobId)
        if let cached { emit(cached) }
        if let baseURL {
            Task.detached { [weak self] in
                _ = try? await self?.refresh(jobId: jobId, baseURL: baseURL, urlSession: urlSession)
            }
        }
        return cached
    }
}
