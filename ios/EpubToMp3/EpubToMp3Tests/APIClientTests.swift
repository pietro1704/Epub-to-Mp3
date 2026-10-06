import XCTest
@testable import EpubToMp3

final class APIClientTests: XCTestCase {

    /// Regression: `session` used to be a computed property that
    /// allocated a fresh `URLSession` on every access, leaking the
    /// delegate queue and tearing down keep-alive connections (and
    /// SSE streams mid-iteration). The fix stores both sessions once
    /// in `init`. Hammer the accessor and assert identity.
    func testSessionIsCachedAcrossManyAccesses() throws {
        let url = URL(string: "http://127.0.0.1:8000")!
        let client = APIClient(baseURL: url)

        let first = client.session
        for _ in 0..<100 {
            XCTAssertTrue(client.session === first,
                          "APIClient.session must be the same URLSession across calls")
        }
    }

    func testStreamingSessionIsCachedAcrossManyAccesses() throws {
        let url = URL(string: "http://127.0.0.1:8000")!
        let client = APIClient(baseURL: url)

        let first = client.streamingSession
        for _ in 0..<100 {
            XCTAssertTrue(client.streamingSession === first,
                          "APIClient.streamingSession must be the same URLSession across calls")
        }
    }

    func testUnaryAndStreamingSessionsAreDistinct() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        XCTAssertFalse(client.session === client.streamingSession,
                       "Unary and SSE sessions must be separate configurations")
    }

    func testUnaryTimeoutsAreBounded() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        XCTAssertEqual(client.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(client.session.configuration.timeoutIntervalForResource, 600)
    }

    func testStreamingTimeoutsAllowInfiniteResource() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        XCTAssertEqual(client.streamingSession.configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(client.streamingSession.configuration.timeoutIntervalForResource, .infinity)
    }

    func testDecoderIsCached() {
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        let first = client.decoder
        for _ in 0..<100 {
            XCTAssertTrue(client.decoder === first,
                          "APIClient.decoder must be the same JSONDecoder across calls")
        }
    }

    func testDistinctClientsHaveDistinctSessions() {
        let a = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        let b = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!)
        XCTAssertFalse(a.session === b.session)
    }

    func testChapterStreamManifestDecodesChunkContract() throws {
        let json = #"{"chapterIndex":3,"chunks":[{"id":"7","index":7,"url":"/api/streams/job/chapters/3/chunks/7","text":"A sentence"}]}"#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(APIClient.ChapterStreamManifest.self, from: json)
        XCTAssertEqual(manifest.chapterIndex, 3)
        XCTAssertEqual(manifest.chunks.map(\.index), [7])
        XCTAssertEqual(manifest.chunks.first?.url, "/api/streams/job/chapters/3/chunks/7")
        XCTAssertEqual(manifest.chunks.first?.text, "A sentence")
    }

    func testChapterStreamManifestAllowsEmptyInProgressChunkList() throws {
        let json = #"{"chapterIndex":0,"chunks":[]}"#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(APIClient.ChapterStreamManifest.self, from: json)
        XCTAssertTrue(manifest.chunks.isEmpty)
    }

    func testStreamProducerObservationKeepsItsOwnClockAndExcludesUnknownMetadata() throws {
        let observation = #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55,"bookTitle":"Private title"}"#
        let chunk = try decodeObservedChunk(observation)
        let producer = try XCTUnwrap(chunk.observation)
        XCTAssertEqual(producer.attemptID, UUID(uuidString: "FE0D56D1-3661-49DB-89D4-324A355FB35A"))
        XCTAssertEqual(producer.segmentReadyElapsedNanoseconds, 40)
        XCTAssertEqual(producer.artifactPublishedElapsedNanoseconds, 55)
        let exported = try JSONSerialization.jsonObject(with: JSONEncoder().encode(producer)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(exported).keys), Set([
            "version", "attemptId", "segmentReadyElapsedNanoseconds",
            "artifactPublishedElapsedNanoseconds"
        ]))
    }

    func testInvalidProducerMetadataDoesNotDiscardPlayableChunk() throws {
        let valid = #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}"#
        let invalid = [
            "null", "{}", "[]", "true", "\"invalid\"",
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            valid.replacingOccurrences(of: "FE0D56D1-3661-49DB-89D4-324A355FB35A", with: "invalid"),
            valid.replacingOccurrences(of: ":40", with: ":-1"),
            valid.replacingOccurrences(of: ":40", with: ":true"),
            valid.replacingOccurrences(of: ":40", with: ":\"40\""),
            valid.replacingOccurrences(of: ":55", with: ":39"),
            valid.replacingOccurrences(of: ":55", with: ":18446744073709551616")
        ]
        for payload in invalid {
            let chunk = try decodeObservedChunk(payload)
            XCTAssertNil(chunk.observation)
            XCTAssertEqual(chunk.id, "publication-a")
            XCTAssertEqual(chunk.index, 7)
            XCTAssertEqual(chunk.url, "/audio/publication-a")
            XCTAssertEqual(chunk.text, "A sentence")
        }
    }

    func testMissingProducerMetadataKeepsLegacyChunkReadable() throws {
        let chunk = try JSONDecoder().decode(APIClient.StreamChunk.self, from: Data(
            #"{"id":"7","index":7,"url":"/audio/7"}"#.utf8))
        XCTAssertNil(chunk.observation)
        XCTAssertNil(chunk.text)
    }

    func testManifestObservationFlowsThroughClientWithoutChangingAudioBytes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProducerManifestProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(baseURL: URL(string: "https://producer.test")!,
                               session: session, streamingSession: nil)
        for jobID in ["valid", "invalid"] {
            let manifest = try await client.fetchChapterStream(jobId: jobID, chapterIndex: 1)
            let chunk = try XCTUnwrap(manifest.chunks.first)
            XCTAssertEqual(chunk.index, 0)
            XCTAssertEqual(chunk.observation != nil, jobID == "valid")
            let audio = try await client.fetchChapterStreamChunk(
                jobId: jobID, chapterIndex: manifest.chapterIndex, chunkId: chunk.id)
            XCTAssertEqual(audio, Data([0x49, 0x44, 0x33, 0x04, 0x00]))
        }
    }

    private func decodeObservedChunk(_ observation: String) throws -> APIClient.StreamChunk {
        let json = """
        {"id":"publication-a","index":7,"url":"/audio/publication-a",\
        "text":"A sentence","observation":\(observation)}
        """
        return try JSONDecoder().decode(APIClient.StreamChunk.self, from: Data(json.utf8))
    }

    func testAuthorizedChunkDownloadReturnsMatchingReceiptAndBypassesCache() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let journey = UUID()
        let authorization = try XCTUnwrap(diagnostics.authorization(for: journey))
        let capture = ReceiptRequestCapture()
        let (client, session) = receiptClient(capture: capture)
        defer { session.invalidateAndCancel(); ReceiptHTTPProtocol.remove(capture) }
        let result = try await client.fetchChapterStreamChunk(
            jobId: "valid", chapterIndex: 1, chunkId: "7", authorization: authorization)
        XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.journeyID, journey)
        XCTAssertEqual(receipt.publicationID, "7")
        XCTAssertEqual(receipt.requestID.uuidString.lowercased(), ReceiptHTTPProtocol.requestID)
        let request = try XCTUnwrap(capture.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Playback-Journey-ID"), journey.uuidString)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let encoded = try JSONEncoder().encode(receipt)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), Set(["journeyId", "requestId", "publicationId"]))
        XCTAssertEqual(try JSONDecoder().decode(LatencyObservation.StreamRequestReceipt.self, from: encoded), receipt)
    }

    func testAbsentOrRevokedAuthorizationKeepsLegacyAudioWithoutHeaders() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let old = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        diagnostics.deactivate()
        diagnostics.activate()
        let capture = ReceiptRequestCapture()
        let (client, session) = receiptClient(capture: capture)
        defer { session.invalidateAndCancel(); ReceiptHTTPProtocol.remove(capture) }
        for authorization in [nil, old] {
            let result = try await client.fetchChapterStreamChunk(
                jobId: "valid", chapterIndex: 1, chunkId: "7", authorization: authorization)
            XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
            XCTAssertNil(result.receipt)
            let request = try XCTUnwrap(capture.lastRequest)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Playback-Journey-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cache-Control"))
        }
        let legacy = try await client.fetchChapterStreamChunk(jobId: "valid", chapterIndex: 1, chunkId: "7")
        XCTAssertEqual(legacy, ReceiptHTTPProtocol.audio)
        XCTAssertNil(capture.lastRequest?.value(forHTTPHeaderField: "X-Playback-Journey-ID"))
    }

    func testMalformedOrForeignReceiptDoesNotDiscardAudio() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let authorization = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        let capture = ReceiptRequestCapture()
        let (client, session) = receiptClient(capture: capture)
        defer { session.invalidateAndCancel(); ReceiptHTTPProtocol.remove(capture) }
        for mode in ["missing", "wrong-journey", "wrong-publication", "bad-request", "foreign-origin"] {
            let result = try await client.fetchChapterStreamChunk(
                jobId: mode, chapterIndex: 1, chunkId: "7", authorization: authorization)
            XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
            XCTAssertNil(result.receipt, mode)
        }
    }

    func testSessionRevokedDuringDownloadCannotRetainReceipt() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let authorization = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        let capture = ReceiptRequestCapture(onRequest: { diagnostics.deactivate() })
        let (client, session) = receiptClient(capture: capture)
        defer { session.invalidateAndCancel(); ReceiptHTTPProtocol.remove(capture) }
        let result = try await client.fetchChapterStreamChunk(
            jobId: "valid", chapterIndex: 1, chunkId: "7", authorization: authorization)
        XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
        XCTAssertNotNil(capture.lastRequest?.value(forHTTPHeaderField: "X-Playback-Journey-ID"))
        XCTAssertNil(result.receipt)
    }

    func testCrossOriginRedirectNeverForwardsJourneyHeader() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let authorization = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        let capture = ReceiptRequestCapture()
        let (client, session) = receiptClient(capture: capture)
        defer { session.invalidateAndCancel(); ReceiptHTTPProtocol.remove(capture) }
        let result = try await client.fetchChapterStreamChunk(
            jobId: "redirect", chapterIndex: 1, chunkId: "7", authorization: authorization)
        XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
        XCTAssertEqual(capture.lastRequest?.url?.host, "foreign.receipt.test")
        XCTAssertNil(capture.lastRequest?.value(forHTTPHeaderField: "X-Playback-Journey-ID"))
        XCTAssertNil(result.receipt)
    }

    func testReceiptRejectsNonOpaquePublicationIdentity() throws {
        for publication in ["Private_Book_Title", "/private/audio.mp3", "", "１２３",
                            String(repeating: "1", count: 21), String(repeating: "a", count: 65_536)] {
            XCTAssertNil(LatencyObservation.StreamRequestReceipt(
                journeyID: UUID(), requestID: UUID(), publicationID: publication))
        }
    }

    func testLegacyStreamingClientCannotManufactureReceipt() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let client: any JobStreamingClient = LegacyReceiptClient()
        let result = try await client.fetchChapterStreamChunk(
            jobId: "legacy", chapterIndex: 1, chunkId: "7",
            authorization: diagnostics.authorization(for: UUID()))
        XCTAssertEqual(result.data, ReceiptHTTPProtocol.audio)
        XCTAssertNil(result.receipt)
    }

    private func receiptClient(capture: ReceiptRequestCapture) -> (APIClient, URLSession) {
        ReceiptHTTPProtocol.register(capture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        return (APIClient(baseURL: URL(string: "https://\(capture.host)")!,
                          session: session, streamingSession: nil), session)
    }
}

private struct LegacyReceiptClient: JobStreamingClient {
    func fetchJob(id: String) async throws -> JobSnapshot { throw APIError.invalidBaseURL }
    func fetchChapterStream(jobId: String, chapterIndex: Int) async throws -> APIClient.ChapterStreamManifest {
        .init(chapterIndex: chapterIndex, chunks: [])
    }
    func fetchChapterStreamChunk(jobId: String, chapterIndex: Int, chunkId: String) async throws -> Data {
        ReceiptHTTPProtocol.audio
    }
    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ReceiptRequestCapture: @unchecked Sendable {
    let host = "\(UUID().uuidString.lowercased()).receipt.test"
    private let lock = NSLock()
    private var request: URLRequest?
    let onRequest: @Sendable () -> Void
    init(onRequest: @escaping @Sendable () -> Void = {}) { self.onRequest = onRequest }
    var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
    func record(_ value: URLRequest) { lock.lock(); request = value; lock.unlock(); onRequest() }
}

private final class ReceiptHTTPProtocol: URLProtocol {
    static let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00])
    static let requestID = "fe0d56d1-3661-49db-89d4-324a355fb35a"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captures: [String: ReceiptRequestCapture] = [:]
    static func register(_ capture: ReceiptRequestCapture) {
        lock.lock(); captures[capture.host] = capture; lock.unlock()
    }
    static func remove(_ capture: ReceiptRequestCapture) {
        lock.lock(); captures.removeValue(forKey: capture.host); lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".receipt.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let owner = request.value(forHTTPHeaderField: "X-Test-Owner") ?? url.host ?? ""
        Self.lock.lock(); let capture = Self.captures[owner]; Self.lock.unlock()
        capture?.record(request)
        if url.path.contains("/redirect/") {
            var redirected = request
            redirected.url = URL(string: "https://foreign.receipt.test/final")!
            redirected.setValue(owner, forHTTPHeaderField: "X-Test-Owner")
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": redirected.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        var headers = ["X-Playback-Journey-ID": request.value(forHTTPHeaderField: "X-Playback-Journey-ID") ?? "",
                       "X-Stream-Request-ID": Self.requestID,
                       "X-Stream-Publication-ID": "7"]
        if url.path.contains("/missing/") { headers = [:] }
        if url.path.contains("/wrong-journey/") { headers["X-Playback-Journey-ID"] = UUID().uuidString }
        if url.path.contains("/wrong-publication/") { headers["X-Stream-Publication-ID"] = "8" }
        if url.path.contains("/bad-request/") { headers["X-Stream-Request-ID"] = "private-metadata" }
        let responseURL = url.path.contains("/foreign-origin/") ? URL(string: "https://foreign.receipt.test/final")! : url
        let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.audio)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ProducerManifestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "producer.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        if url.path.contains("/chunks/") {
            body = Data([0x49, 0x44, 0x33, 0x04, 0x00])
        } else {
            let observation = url.path.contains("/invalid/") ? "{}" :
                #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}"#
            body = Data("""
            {"chapterIndex":1,"chunks":[{"id":"publication-a","index":0,\
            "url":"\(url.path)/chunks/publication-a","observation":\(observation)}]}
            """.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
