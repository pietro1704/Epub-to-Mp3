import Foundation
import os

enum APIError: LocalizedError {
    case invalidBaseURL
    case http(status: Int, body: String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Backend URL is not valid. Check Settings."
        case .http(let status, let body):
            return "Server responded with HTTP \(status). \(body.prefix(200))"
        case .decoding(let err):
            return "Failed to decode response: \(err.localizedDescription)"
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

/// Operations needed by the job-detail streaming coordinator. Keeping this
/// narrow lets the coordinator be verified with deterministic media events
/// while the production app continues to use the concrete HTTP client.
protocol JobStreamingClient: Sendable {
    func fetchJob(id: String) async throws -> JobSnapshot
    func fetchChapterStream(jobId: String, chapterIndex: Int) async throws -> APIClient.ChapterStreamManifest
    func fetchChapterStreamChunk(jobId: String, chapterIndex: Int, chunkId: String) async throws -> Data
    func fetchChapterStreamChunk(
        jobId: String, chapterIndex: Int, chunkId: String,
        authorization: StreamingDiagnosticsSession.Authorization?
    ) async throws -> APIClient.StreamChunkDownload
    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error>
}

extension JobStreamingClient {
    func fetchChapterStreamChunk(
        jobId: String, chapterIndex: Int, chunkId: String,
        authorization: StreamingDiagnosticsSession.Authorization?
    ) async throws -> APIClient.StreamChunkDownload {
        let data = try await fetchChapterStreamChunk(jobId: jobId, chapterIndex: chapterIndex, chunkId: chunkId)
        return .init(data: data, receipt: nil)
    }
}

/// Thin Foundation-only API client.
///
/// Mirrors the contract used by `web/src/services/ConversionService.ts`:
///   - GET  /api/sessions
///   - GET  /api/jobs/{id}/stream      (SSE — `text/event-stream`)
///
/// Note: the TS client also exposes /api/jobs/{id}/events historically; the
/// canonical streaming endpoint on `server.py` is `/api/jobs/{id}/stream`,
/// which is what we hit here.
///
/// `APIClient` is a `final class` so that `session` and `decoder` are
/// allocated exactly once per client. Previous versions exposed `session`
/// as a computed property, which leaked a brand-new `URLSession` (and its
/// delegate retain) on every call — and tore the session down mid-flight
/// during SSE iteration.
final class APIClient: @unchecked Sendable {
    let baseURL: URL

    /// Shared session for unary requests. Configured once; reused for
    /// every regular call (sessions, job snapshot, telemetry, log,
    /// upload, submit).
    let session: URLSession

    /// Dedicated session for SSE streams. Same `timeoutIntervalForRequest`
    /// budget (so we detect server death), but `timeoutIntervalForResource`
    /// is `.infinity` because the stream has no natural end.
    let streamingSession: URLSession

    /// Single decoder. JobSnapshot et al. already use camelCase coding
    /// keys, so no `keyDecodingStrategy` is set — the wire format is
    /// honoured verbatim and we just save the per-call allocation.
    let decoder: JSONDecoder

    static let logger = Logger(subsystem: "com.pietrop.epubtomp3", category: "api")

    convenience init(baseURL: URL) {
        self.init(baseURL: baseURL, session: nil, streamingSession: nil)
    }

    init(
        baseURL: URL,
        session: URLSession?,
        streamingSession: URLSession?
    ) {
        self.baseURL = baseURL

        if let session {
            self.session = session
        } else {
            let unary = URLSessionConfiguration.default
            unary.waitsForConnectivity = true
            unary.timeoutIntervalForRequest = 30
            unary.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: unary)
        }

        if let streamingSession {
            self.streamingSession = streamingSession
        } else {
            let streaming = URLSessionConfiguration.default
            streaming.waitsForConnectivity = true
            streaming.timeoutIntervalForRequest = 60
            // SSE streams have no natural end — we rely on cancellation,
            // not resource timeout.
            streaming.timeoutIntervalForResource = .infinity
            self.streamingSession = URLSession(configuration: streaming)
        }

        self.decoder = JSONDecoder()
    }

    deinit {
        // Invalidate to release the delegate queue + outstanding tasks
        // promptly when the client goes away.
        session.invalidateAndCancel()
        streamingSession.invalidateAndCancel()
    }

    // MARK: Sessions

    func fetchSessions(last: Int = 100) async throws -> [SessionRecord] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/sessions"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "last", value: String(last))]
        guard let url = components?.url else { throw APIError.invalidBaseURL }

        do {
            let (data, response) = try await session.data(from: url)
            try Self.assertOK(response: response, data: data)
            let envelope = try decoder.decode(SessionsResponse.self, from: data)
            // Backend returns oldest-first; reverse so the latest run is on top.
            return envelope.sessions.reversed()
        } catch let err as APIError {
            throw err
        } catch let decErr as DecodingError {
            Self.logger.error("fetchSessions decode failed: \(String(describing: decErr), privacy: .public)")
            throw APIError.decoding(decErr)
        } catch {
            Self.logger.error("fetchSessions transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
        }
    }

    // MARK: Job snapshot

    /// Fetch a single job snapshot via `GET /api/jobs/{id}`. Mirrors
    /// `JobStatus` in `python_app/server.py`.
    func fetchJob(id: String) async throws -> JobSnapshot {
        let url = baseURL.appendingPathComponent("api/jobs/\(id)")
        do {
            let (data, response) = try await session.data(from: url)
            try Self.assertOK(response: response, data: data)
            return try decoder.decode(JobSnapshot.self, from: data)
        } catch let err as APIError {
            throw err
        } catch let decErr as DecodingError {
            Self.logger.error("fetchJob(\(id, privacy: .public)) decode failed: \(String(describing: decErr), privacy: .public)")
            throw APIError.decoding(decErr)
        } catch {
            Self.logger.error("fetchJob(\(id, privacy: .public)) transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
        }
    }

    /// Decode a single SSE `data:` payload into a `JobSnapshot`. Returns
    /// nil if the payload isn't a snapshot (some events are heartbeats or
    /// progress fragments).
    ///
    /// Static helper retained for call-site compatibility — uses a
    /// throwaway decoder because callers don't carry an `APIClient`
    /// reference. The hot path uses `client.decoder` via the SSE stream.
    static func decodeSnapshot(from rawPayload: String) -> JobSnapshot? {
        guard let data = rawPayload.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(JobSnapshot.self, from: data)
        } catch {
            logger.debug("decodeSnapshot ignored payload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: SSE

    /// Streams raw `data:` payloads from the backend's SSE endpoint as an
    /// `AsyncThrowingStream<String, Error>`. Cancelling the iterating task
    /// tears down the underlying URLSession data task automatically.
    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [streamingSession, baseURL] in
                do {
                    let url = baseURL.appendingPathComponent("api/jobs/\(jobId)/stream")
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw APIError.http(status: http.statusCode, body: "")
                    }

                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            // Blank line marks end of an SSE event.
                            if !dataBuffer.isEmpty {
                                continuation.yield(JobEvent(receivedAt: Date(),
                                                            rawPayload: dataBuffer))
                                dataBuffer = ""
                            }
                            continue
                        }
                        if line.hasPrefix(":") { continue }            // heartbeat comment
                        if line.hasPrefix("data:") {
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            dataBuffer += dataBuffer.isEmpty ? payload : "\n" + payload
                        }
                        // event:/id:/retry: lines are intentionally ignored in this slice.
                    }
                    continuation.finish()
                } catch {
                    Self.logger.error("eventStream(\(jobId, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Telemetry

    struct TelemetrySnapshot: Decodable, Sendable {
        struct EngineSample: Decodable, Sendable {
            let engine: String
            let charsPerSecond: Double?
            let totalChars: Int?
            let totalChapters: Int?
        }
        let recent: [EngineSample]?
        let perEngine: [String: EngineSample]?
    }

    /// Best-effort GET /api/telemetry — backend shape varies between
    /// versions, so we accept anything decodable and let the UI pick
    /// the bits it knows about.
    func fetchTelemetry() async throws -> Data {
        let url = baseURL.appendingPathComponent("api/telemetry")
        do {
            let (data, response) = try await session.data(from: url)
            try Self.assertOK(response: response, data: data)
            return data
        } catch let err as APIError {
            throw err
        } catch {
            Self.logger.error("fetchTelemetry transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
        }
    }

    // MARK: Logs

    /// Tail the conversion log for a job. Returns the raw text body of
    /// `GET /api/jobs/{id}/log`. Backend serves this as a plain-text
    /// response, so we don't decode JSON.
    func fetchJobLog(id: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/jobs/\(id)/log")
        do {
            let (data, response) = try await session.data(from: url)
            try Self.assertOK(response: response, data: data)
            return String(data: data, encoding: .utf8) ?? ""
        } catch let err as APIError {
            throw err
        } catch {
            Self.logger.error("fetchJobLog(\(id, privacy: .public)) transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
        }
    }

    // MARK: Helpers

    static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: body)
        }
    }
}

extension APIClient: JobStreamingClient {}
