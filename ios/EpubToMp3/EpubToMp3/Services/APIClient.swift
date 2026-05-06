import Foundation

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
struct APIClient {
    let baseURL: URL

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        // SSE streams have no natural end — we rely on cancellation, not timeout.
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
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
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(SessionsResponse.self, from: data)
            // Backend returns oldest-first; reverse so the latest run is on top.
            return envelope.sessions.reversed()
        } catch let err as APIError {
            throw err
        } catch let decErr as DecodingError {
            throw APIError.decoding(decErr)
        } catch {
            throw APIError.transport(error)
        }
    }

    // MARK: SSE

    /// Streams raw `data:` payloads from the backend's SSE endpoint as an
    /// `AsyncThrowingStream<String, Error>`. Cancelling the iterating task
    /// tears down the underlying URLSession data task automatically.
    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/jobs/\(jobId)/stream")
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                    let (bytes, response) = try await session.bytes(for: request)
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
