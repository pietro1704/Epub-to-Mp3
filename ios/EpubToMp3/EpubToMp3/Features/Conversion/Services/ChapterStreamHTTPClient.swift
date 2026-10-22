import Foundation

/// Legacy HTTP media transport; the APIClient instance retains its sessions.
extension APIClient {
    struct StreamChunkDownload: Sendable {
        let data: Data
        let receipt: LatencyObservation.StreamRequestReceipt?
    }
    struct StreamChunk: Decodable, Sendable {
        let id: String
        let index: Int
        let url: String
        let text: String?
        let observation: LatencyObservation.ProducerObservation?

        init(
            id: String, index: Int, url: String, text: String?,
            observation: LatencyObservation.ProducerObservation? = nil
        ) {
            self.id = id
            self.index = index
            self.url = url
            self.text = text
            self.observation = observation
        }

        private enum CodingKeys: String, CodingKey {
            case id, index, url, text, observation
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            index = try values.decode(Int.self, forKey: .index)
            url = try values.decode(String.self, forKey: .url)
            text = try values.decodeIfPresent(String.self, forKey: .text)
            // Optional diagnostics must not make otherwise playable audio fail.
            observation = try? values.decode(
                LatencyObservation.ProducerObservation.self, forKey: .observation)
        }
    }

    struct ChapterStreamManifest: Decodable, Sendable {
        let chapterIndex: Int
        let chunks: [StreamChunk]
    }
    /// Fetch the chunks already synthesized for one chapter. Chunks are
    /// deliberately requested independently from the job SSE: the SSE
    /// carries progress metadata, while this endpoint is the media contract.
    func fetchChapterStream(jobId: String, chapterIndex: Int) async throws -> ChapterStreamManifest {
        let url = baseURL.appendingPathComponent(
            "api/streams/\(jobId)/chapters/\(chapterIndex)"
        )
        do {
            let (data, response) = try await session.data(from: url)
            try Self.assertOK(response: response, data: data)
            return try decoder.decode(ChapterStreamManifest.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decoding(error)
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Download one synthesized stream chunk into memory so the player can
    /// enqueue it immediately, before the complete chapter MP3 exists.
    func fetchChapterStreamChunk(jobId: String, chapterIndex: Int, chunkId: String) async throws -> Data {
        try await fetchChapterStreamChunk(
            jobId: jobId, chapterIndex: chapterIndex, chunkId: chunkId, authorization: nil).data
    }

    func fetchChapterStreamChunk(
        jobId: String, chapterIndex: Int, chunkId: String,
        authorization: StreamingDiagnosticsSession.Authorization?
    ) async throws -> StreamChunkDownload {
        let url = baseURL.appendingPathComponent(
            "api/streams/\(jobId)/chapters/\(chapterIndex)/chunks/\(chunkId)"
        )
        do {
            let active = authorization.flatMap { $0.isValid ? $0 : nil }
            let data: Data
            let response: URLResponse
            if let active {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue(active.journeyID.uuidString, forHTTPHeaderField: "X-Playback-Journey-ID")
                (data, response) = try await session.data(
                    for: request, delegate: ChapterStreamRedirectPolicy(origin: url, authorization: active))
            } else {
                (data, response) = try await session.data(from: url)
            }
            try Self.assertOK(response: response, data: data)
            guard !data.isEmpty else { throw APIError.http(status: 502, body: "Empty audio chunk") }
            var receipt: LatencyObservation.StreamRequestReceipt?
            if let active, active.isValid, let http = response as? HTTPURLResponse,
               ChapterStreamRedirectPolicy.sameOrigin(http.url, url),
               let echoedJourney = http.value(forHTTPHeaderField: "X-Playback-Journey-ID"),
               echoedJourney.lowercased() == active.journeyID.uuidString.lowercased(),
               http.value(forHTTPHeaderField: "X-Stream-Publication-ID") == chunkId,
               let requestValue = http.value(forHTTPHeaderField: "X-Stream-Request-ID"),
               let requestID = UUID(uuidString: requestValue),
               requestID.uuidString.lowercased() == requestValue.lowercased() {
                receipt = .init(journeyID: active.journeyID, requestID: requestID, publicationID: chunkId)
            }
            return .init(data: data, receipt: receipt)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

}
