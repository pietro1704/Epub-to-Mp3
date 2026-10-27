#if os(iOS) || os(macOS)
import Foundation
import Network
import XCTest

/// Real loopback HTTP with deterministic range failures; never contacts public hosts.
final class SpeechModelRangeHTTPFixture: @unchecked Sendable {
    enum Scenario: CaseIterable, Equatable, Sendable {
        case normal, interruptOnce, changedValidator, ignoredRange, invalidRange
    }

    let ready = XCTestExpectation(description: "Range proof loopback listener ready")
    let pausedRange = XCTestExpectation(description: "Second range held before response")
    private let queue = DispatchQueue(label: "SpeechModelRangeHTTPFixture")
    private let listener: NWListener
    private let lock = NSLock()
    private var boundPort: UInt16?
    private var receivedHeaders: [[String: String]] = []
    private var connections: [NWConnection] = []
    private var interrupted = false
    let payload: Data
    let scenario: Scenario
    private let pauseAfterFirstRange: Bool

    init(payload: Data, scenario: Scenario, pauseAfterFirstRange: Bool = false) throws {
        self.payload = payload
        self.scenario = scenario
        self.pauseAfterFirstRange = pauseAfterFirstRange
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            lock.lock()
            boundPort = listener.port?.rawValue
            lock.unlock()
            ready.fulfill()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connections.append(connection)
            connection.start(queue: queue)
            receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort.flatMap { URL(string: "http://127.0.0.1:\($0)/model.onnx") }
    }

    var requests: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return receivedHeaders
    }

    func close() {
        queue.async {
            self.connections.forEach { $0.cancel() }
            self.listener.cancel()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self else { return }
            var request = accumulated
            if let bytes { request.append(bytes) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(connection, request: request)
            } else if !done, error == nil, request.count < 32 * 1024 {
                receive(connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        lock.lock()
        receivedHeaders.append(headers)
        lock.unlock()
        let range = headers["range"]?.dropFirst(6).split(separator: "-")
        let start = range?.first.flatMap { Int($0) } ?? 0
        let end = min(range?.last.flatMap { Int($0) } ?? payload.count - 1, payload.count - 1)
        if pauseAfterFirstRange, start > 0 {
            pausedRange.fulfill()
            return
        }
        let changed = scenario == .changedValidator && start > 0
        let tag = changed ? "\"v2\"" : "\"v1\""
        let full = headers["range"] == nil || scenario == .ignoredRange
        let body = full ? payload : Data(payload[start...end])
        let status = full ? 200 : 206
        let contentRange = scenario == .invalidRange ? "bytes 1-\(end)/\(payload.count)"
            : "bytes \(start)-\(end)/\(payload.count)"
        var response = "HTTP/1.1 \(status) OK\r\nConnection: close\r\n"
            + "Content-Length: \(body.count)\r\nETag: \(tag)\r\nAccept-Ranges: bytes\r\n"
        if !full { response += "Content-Range: \(contentRange)\r\n" }
        response += "\r\n"
        var wireBytes = Data(response.utf8)
        if scenario == .interruptOnce, start > 0, !interrupted {
            interrupted = true
            wireBytes.append(body.prefix(max(1, body.count / 2)))
        } else {
            wireBytes.append(body)
        }
        connection.send(content: wireBytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Test-only bridge preserves production HTTPS admission while forwarding HTTP
/// headers and bytes to the real loopback fixture. It makes no TLS/background claim.
final class SpeechModelRangeLoopbackProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var destinations: [URL: URL] = [:]
    private var session: URLSession?
    private var forwardedTask: URLSessionDataTask?

    static func register(_ source: URL, destination: URL) {
        lock.lock()
        destinations[source] = destination
        lock.unlock()
    }

    static func unregister(_ source: URL) {
        lock.lock()
        destinations.removeValue(forKey: source)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models.range.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let destination = request.url.flatMap { Self.destinations[$0] }
        Self.lock.unlock()
        guard let destination, let source = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var forwarded = request
        forwarded.url = destination
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration)
        self.session = session
        forwardedTask = session.dataTask(with: forwarded) { [weak self] bytes, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let response = response as? HTTPURLResponse else { return }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                if let key = $1.key as? String { $0[key] = String(describing: $1.value) }
            }
            let mapped = HTTPURLResponse(
                url: source, statusCode: response.statusCode,
                httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: mapped, cacheStoragePolicy: .notAllowed)
            if let bytes { client?.urlProtocol(self, didLoad: bytes) }
            client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }

    override func stopLoading() {
        forwardedTask?.cancel()
        session?.invalidateAndCancel()
    }
}
#endif
