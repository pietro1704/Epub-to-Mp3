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

    private static let logger = Logger(subsystem: "com.pietrop.epubtomp3", category: "api")

    init(baseURL: URL) {
        self.baseURL = baseURL

        let unary = URLSessionConfiguration.default
        unary.waitsForConnectivity = true
        unary.timeoutIntervalForRequest = 30
        unary.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: unary)

        let streaming = URLSessionConfiguration.default
        streaming.waitsForConnectivity = true
        streaming.timeoutIntervalForRequest = 60
        // SSE streams have no natural end — we rely on cancellation,
        // not resource timeout.
        streaming.timeoutIntervalForResource = .infinity
        self.streamingSession = URLSession(configuration: streaming)

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

    // MARK: Conversion submission

    /// Options forwarded as multipart form fields to `POST /api/convert`.
    /// Only the most common knobs are surfaced — the FastAPI handler
    /// accepts dozens of optional fields, callers can extend this struct
    /// without changing the endpoint contract.
    struct ConvertOptions: Sendable {
        var engine: String = "edge"
        var voice: String? = nil
        var language: String? = nil
        var chapters: String? = nil
        var fromChapterToEnd: String? = nil
        var fromChapterToChapter: String? = nil
        var clearCache: Bool = false
        var forceReprocess: Bool = false
        var formattingCues: Bool = true
        var maxPerformance: Bool = false
        var uiLanguage: String = "pt"
        var priorityChapterIndex: Int? = nil

        static let `default` = ConvertOptions()
    }

    struct ConvertResponse: Decodable, Sendable {
        let jobId: String
        let status: String?

        enum CodingKeys: String, CodingKey {
            case jobId = "jobId"
            case status
        }
    }

    /// Tell the backend to convert a file the user already has on disk.
    /// Backed by `POST /api/uploads/local` (desktop-only path, hits the
    /// local backend) so we don't have to upload hundreds of MB of
    /// EPUB/PDF for a local file. Returns the upload id that
    /// `submitConversion` then forwards.
    func registerLocalUpload(path: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/uploads/local")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["path": path.path])
        req.httpBody = body
        do {
            let (data, response) = try await session.data(for: req)
            try Self.assertOK(response: response, data: data)
            let decoded = try decoder.decode([String: String].self, from: data)
            guard let id = decoded["uploadId"] ?? decoded["upload_id"] ?? decoded["id"] else {
                throw APIError.decoding(NSError(domain: "APIClient", code: 100,
                                                userInfo: [NSLocalizedDescriptionKey: "uploadId missing"]))
            }
            return id
        } catch let err as APIError {
            throw err
        } catch let decErr as DecodingError {
            Self.logger.error("registerLocalUpload decode failed: \(String(describing: decErr), privacy: .public)")
            throw APIError.decoding(decErr)
        } catch {
            Self.logger.error("registerLocalUpload transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
        }
    }

    /// Upload a book's bytes for remote parsing. This is used by iOS and by
    /// server-only formats whose local embedded runtime cannot parse them.
    func uploadBook(at fileURL: URL) async throws -> String {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (responseData, response) = try await session.data(for: request)
            try Self.assertOK(response: response, data: responseData)
            let decoded = try decoder.decode([String: String].self, from: responseData)
            guard let uploadID = decoded["uploadId"] ?? decoded["upload_id"] ?? decoded["id"] else {
                throw APIError.decoding(NSError(
                    domain: "APIClient",
                    code: 101,
                    userInfo: [NSLocalizedDescriptionKey: "uploadId missing"]
                ))
            }
            return uploadID
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Fetch parsed fulltext for an upload and let the caller persist it in
    /// the same local cache used by embedded parsing.
    func fetchUploadedFulltext(uploadID: String) async throws -> EbookFulltext {
        let endpoint = baseURL.appendingPathComponent("api/uploads/\(uploadID)/fulltext")
        do {
            let (data, response) = try await session.data(from: endpoint)
            try Self.assertOK(response: response, data: data)
            return try decoder.decode(EbookFulltext.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Submit a conversion. Either `localPath` (desktop) or `uploadedFile`
    /// (mobile or remote backend) must be provided. Returns the new job id.
    func submitConversion(
        localPath: URL? = nil,
        uploadedFile: (data: Data, filename: String)? = nil,
        options: ConvertOptions = .default
    ) async throws -> ConvertResponse {
        let endpoint = baseURL.appendingPathComponent("api/convert")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                        .data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        if let localPath {
            // Path 1 — desktop-local: register the path with the backend
            // and forward only the `upload_id`.
            let uploadId = try await registerLocalUpload(path: localPath)
            appendField(name: "upload_id", value: uploadId)
        } else if let uploadedFile {
            // Path 2 — multipart upload of the raw bytes.
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadedFile.filename)\"\r\n"
                        .data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n"
                        .data(using: .utf8)!)
            body.append(uploadedFile.data)
            body.append("\r\n".data(using: .utf8)!)
        } else {
            throw APIError.invalidBaseURL
        }

        appendField(name: "engine", value: options.engine)
        if let v = options.voice { appendField(name: "voice", value: v) }
        if let l = options.language { appendField(name: "language", value: l) }
        if let ch = options.chapters { appendField(name: "chapters", value: ch) }
        if let f = options.fromChapterToEnd { appendField(name: "fromChapterToEnd", value: f) }
        if let r = options.fromChapterToChapter { appendField(name: "fromChapterToChapter", value: r) }
        appendField(name: "clear_cache", value: options.clearCache ? "1" : "0")
        appendField(name: "force_reprocess", value: options.forceReprocess ? "1" : "0")
        if let priorityChapterIndex = options.priorityChapterIndex {
            appendField(name: "priority_chapter_index", value: String(priorityChapterIndex))
        }
        appendField(name: "formatting_cues", value: options.formattingCues ? "on" : "off")
        appendField(name: "max_performance", value: options.maxPerformance ? "1" : "0")
        appendField(name: "ui_language", value: options.uiLanguage)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        do {
            let (data, response) = try await session.data(for: req)
            try Self.assertOK(response: response, data: data)
            return try decoder.decode(ConvertResponse.self, from: data)
        } catch let err as APIError {
            throw err
        } catch let decErr as DecodingError {
            Self.logger.error("submitConversion decode failed: \(String(describing: decErr), privacy: .public)")
            throw APIError.decoding(decErr)
        } catch {
            Self.logger.error("submitConversion transport failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.transport(error)
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

    private static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: body)
        }
    }
}
