import Foundation
import os

extension APIClient {
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

}
