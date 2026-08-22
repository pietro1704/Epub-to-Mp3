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

    func testEventStreamURLCarriesOnlyTheJourneyCorrelationID() throws {
        let journeyID = UUID(uuidString: "5B6039B7-6471-4CC0-B8F2-C653FE0D093C")!

        let url = try XCTUnwrap(
            APIClient.eventStreamURL(
                baseURL: URL(string: "http://127.0.0.1:8000")!,
                jobID: "job-123",
                journeyID: journeyID
            )
        )

        XCTAssertEqual(url.path, "/api/jobs/job-123/stream")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "journey_id", value: journeyID.uuidString.lowercased()),
        ])
    }
}
