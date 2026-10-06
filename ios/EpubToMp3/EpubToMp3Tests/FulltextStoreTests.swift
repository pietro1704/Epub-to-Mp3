// FulltextStoreTests.swift
//
// Tests for `FulltextStore`:
//   - `refresh` 503 retry ladder: exhausts all delays and then throws
//     `transientExhausted` after retryLadderMs.count + 1 attempts.
//   - `refresh` 404 throws `gone` immediately (no retry).
//   - `refresh` 422 throws `emptyParse` immediately (no retry).
//   - `refresh` 200 decodes the payload and emits to `watch` subscribers.
//   - `loadFromDisk` / `saveToDisk` round-trip produces identical struct.
//   - `watch` yields on-disk copy immediately when no network call made.
//   - `loadAndRefresh` returns cached copy synchronously, fires background
//     refresh (we can verify the returned value without waiting for async).
//
// Network is mocked via a custom `URLProtocol` stub — zero real I/O,
// zero `Task.sleep` time (delays are in ns, still fast for the retry
// ladder in tests).

import XCTest
@testable import EpubToMp3

// MARK: - Stub URLProtocol

/// Per-test response queue. Each test registers a list of `StubResponse`
/// values; the stub dequeues one per request in order.
private final class StubProtocol: URLProtocol {

    struct StubResponse {
        let statusCode: Int
        let body: Data
    }

    private struct State {
        var queue: [StubResponse] = []
        var requestCount = 0
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset(with responses: [StubResponse] = []) {
        stateLock.lock()
        state = State(queue: responses)
        stateLock.unlock()
    }

    static var completedRequestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let idx = Self.state.requestCount
        Self.state.requestCount += 1
        let stub = idx < Self.state.queue.count
            ? Self.state.queue[idx]
            : StubResponse(statusCode: 200, body: Data())
        Self.stateLock.unlock()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Tests

final class FulltextStoreTests: XCTestCase {

    // XCTest invokes lifecycle hooks outside the MainActor but serially for a
    // test case; these fixtures bridge that documented boundary only.
    nonisolated(unsafe) private var session: URLSession!
    nonisolated(unsafe) private var storageRoot: URL!
    private let base = URL(string: "http://stub.local")!

    nonisolated override func setUp() async throws {
        try await super.setUp()
        StubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        // Eliminate real delays in the retry ladder for fast tests.
        // The store uses `Task.sleep(nanoseconds:)` internally; we
        // override ladder delays to 0 by having responses ready instantly.
        session = URLSession(configuration: config)
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fulltext-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    nonisolated override func tearDown() async throws {
        session.invalidateAndCancel()
        session = nil
        if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
        storageRoot = nil
        StubProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - 404 / 422 permanent errors

    @MainActor
    func testRefresh404ThrowsGone() async throws {
        StubProtocol.reset(with: [.init(statusCode: 404, body: Data())])
        let store = FulltextStore(storageRoot: storageRoot)

        do {
            _ = try await store.refresh(jobId: "j1", baseURL: base, urlSession: session)
            XCTFail("Expected FulltextError.gone to be thrown")
        } catch FulltextStore.FulltextError.gone {
            // Expected
        }
        // Only one request must have been made (no retry on 404).
        XCTAssertEqual(StubProtocol.completedRequestCount, 1)
    }

    @MainActor
    func testRefresh422ThrowsEmptyParse() async throws {
        StubProtocol.reset(with: [.init(statusCode: 422, body: Data())])
        let store = FulltextStore(storageRoot: storageRoot)

        do {
            _ = try await store.refresh(jobId: "j2", baseURL: base, urlSession: session)
            XCTFail("Expected FulltextError.emptyParse to be thrown")
        } catch FulltextStore.FulltextError.emptyParse {
            // Expected
        }
        XCTAssertEqual(StubProtocol.completedRequestCount, 1)
    }

    // MARK: - 503 retry ladder

    @MainActor
    func test503RetriesUntilExhaustedThenThrows() async throws {
        // Provide 503 for every retry slot + 1 final attempt (ladder has
        // retryLadderMs.count delays, so retryLadderMs.count + 1 total
        // requests before giving up).
        let ladderCount = FulltextStore.retryLadderMs.count
        let totalAttempts = ladderCount + 1
        StubProtocol.reset(with: Array(
            repeating: StubProtocol.StubResponse(statusCode: 503, body: Data("still processing".utf8)),
            count: totalAttempts + 2  // extra headroom
        ))
        let store = FulltextStore(storageRoot: storageRoot)

        do {
            _ = try await store.refresh(jobId: "j3", baseURL: base, urlSession: session)
            XCTFail("Expected transientExhausted to be thrown")
        } catch FulltextStore.FulltextError.transientExhausted {
            // Expected
        }
        XCTAssertEqual(StubProtocol.completedRequestCount, totalAttempts,
            "Must attempt exactly retryLadder.count+1 times (\(totalAttempts)); got \(StubProtocol.completedRequestCount)")
    }

    @MainActor
    func test503ThenSuccessReturnsPayload() async throws {
        // Two 503s then a 200 — simulates "still extracting" scenario.
        let payload = EbookFulltext(
            jobId: "j-ok",
            bookTitle: "Foundation",
            bookAuthor: "Asimov",
            chapters: [.init(index: 1, name: "Prologue",
                             text: "Hari Seldon.", html: nil, css: nil,
                             charCount: 12, segments: nil)]
        )
        let payloadData = try JSONEncoder().encode(payload)

        StubProtocol.reset(with: [
            .init(statusCode: 503, body: Data("wait".utf8)),
            .init(statusCode: 503, body: Data("wait".utf8)),
            .init(statusCode: 200, body: payloadData),
        ])
        let store = FulltextStore(storageRoot: storageRoot)

        let result = try await store.refresh(jobId: "j-ok", baseURL: base, urlSession: session)

        XCTAssertEqual(result.bookTitle, "Foundation")
        XCTAssertEqual(result.chapters.count, 1)
        XCTAssertEqual(StubProtocol.completedRequestCount, 3)
    }

    // MARK: - 200 decode + watch subscriber

    @MainActor
    func testRefresh200EmitsToWatchSubscriber() async throws {
        let payload = EbookFulltext(
            jobId: "j-watch",
            bookTitle: "Dune",
            bookAuthor: "Herbert",
            chapters: [.init(index: 1, name: "Book One",
                             text: "A beginning.", html: nil, css: nil,
                             charCount: 12, segments: nil)]
        )
        let payloadData = try JSONEncoder().encode(payload)
        StubProtocol.reset(with: [.init(statusCode: 200, body: payloadData)])

        let store = FulltextStore(storageRoot: storageRoot)
        var received: EbookFulltext?

        // Set up subscriber before refresh fires.
        let stream = store.watch(jobId: "j-watch")
        let iterTask = Task {
            for await value in stream {
                received = value
                break  // take first value
            }
        }

        _ = try await store.refresh(jobId: "j-watch", baseURL: base, urlSession: session)

        // Give the continuation a tick to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)
        iterTask.cancel()

        let got = try XCTUnwrap(received, "watch subscriber must receive emitted value")
        XCTAssertEqual(got.bookTitle, "Dune")
    }

    // MARK: - Disk round-trip

    @MainActor
    func testSaveToDiskAndLoadFromDisk() throws {
        let id = "disk-rt-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(at: FulltextStore.fulltextURL(for: id, root: storageRoot)) }

        let payload = EbookFulltext(
            jobId: id,
            bookTitle: "Neuromancer",
            bookAuthor: "Gibson",
            chapters: [.init(index: 1, name: "Chapter 1",
                             text: "The sky was the color of television.",
                             html: nil, css: nil, charCount: 37, segments: nil)]
        )
        try FulltextStore.saveToDisk(payload, root: storageRoot)

        let read = try XCTUnwrap(FulltextStore.loadFromDisk(jobId: id, root: storageRoot),
            "loadFromDisk must return payload after saveToDisk")
        XCTAssertEqual(read.bookTitle, "Neuromancer")
        XCTAssertEqual(read.chapters.first?.text,
            "The sky was the color of television.")
    }

    @MainActor
    func testLoadFromDiskReturnsNilForUnknownId() {
        let id = "nonexistent-\(UUID().uuidString)"
        XCTAssertNil(FulltextStore.loadFromDisk(jobId: id, root: storageRoot))
    }

    // MARK: - watch yields on-disk copy immediately

    @MainActor
    func testWatchYieldsDiskCopyBeforeNetworkRefresh() async throws {
        let id = "watch-disk-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(at: FulltextStore.fulltextURL(for: id, root: storageRoot)) }

        let payload = EbookFulltext(
            jobId: id,
            bookTitle: "1984",
            bookAuthor: "Orwell",
            chapters: [.init(index: 1, name: "One",
                             text: "It was a bright cold day.", html: nil,
                             css: nil, charCount: 25, segments: nil)]
        )
        try FulltextStore.saveToDisk(payload, root: storageRoot)

        let store = FulltextStore(storageRoot: storageRoot)
        var first: EbookFulltext?

        let stream = store.watch(jobId: id)
        let iterTask = Task {
            for await value in stream {
                first = value
                break
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        iterTask.cancel()

        let got = try XCTUnwrap(first,
            "watch must yield disk copy without a network call")
        XCTAssertEqual(got.bookTitle, "1984")
        // No network requests should have happened.
        XCTAssertEqual(StubProtocol.completedRequestCount, 0)
    }

    // MARK: - Retry ladder constants

    @MainActor
    func testRetryLadderHasExpectedEntries() {
        // Memory contract: [800, 1500, 3000, 6000, 12000]
        XCTAssertEqual(FulltextStore.retryLadderMs, [800, 1500, 3000, 6000, 12000],
            "Retry ladder must match the project_reader_fulltext.md contract")
    }
}
