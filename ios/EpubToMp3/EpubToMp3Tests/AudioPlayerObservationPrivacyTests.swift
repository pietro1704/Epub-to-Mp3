#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import XCTest
@testable import EpubToMp3

#if os(iOS)
final class AudioSessionEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append("\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)ms:\(event)")
        if events.count > 20 { events.removeFirst() }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.joined(separator: ",")
    }
}
#endif

final class ObservationPrivacyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var interceptedHost = ""
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func configure(host: String) {
        lock.lock()
        defer { lock.unlock() }
        interceptedHost = host
        requests = []
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host == interceptedHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AudioPlayerObservationPrivacyTests: XCTestCase {}
#endif
