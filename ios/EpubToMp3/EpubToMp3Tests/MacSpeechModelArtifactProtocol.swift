#if os(macOS)
import Foundation
@testable import EpubToMp3

/// Test-only HTTP bytes from already verified artifacts. No TLS/background claim.
final class MacSpeechModelArtifactProtocol: URLProtocol, @unchecked Sendable {
    private struct Artifact {
        let file: URL
        let bytes: UInt64
        let sha256: String
    }
    private static let lock = NSLock()
    private static var artifacts: [URL: Artifact] = [:]
    private static var requests = 0
    private var pending: DispatchWorkItem?

    static func configure(_ plan: SpeechModelInstallPlan, source: URL) {
        lock.lock()
        defer { lock.unlock() }
        artifacts = Dictionary(uniqueKeysWithValues: plan.artifacts.map {
            ($0.url, Artifact(file: source.appendingPathComponent($0.name), bytes: $0.expectedBytes, sha256: $0.sha256))
        })
        requests = 0
    }

    static func reset() {
        lock.lock()
        artifacts.removeAll()
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    // This isolated session never falls through to the public network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let work = DispatchWorkItem { [weak self] in self?.respond() }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func stopLoading() { pending?.cancel() }

    private func respond() {
        guard pending?.isCancelled == false, let url = request.url else { return }
        Self.lock.lock()
        let artifact = Self.artifacts[url]
        Self.requests += 1
        Self.lock.unlock()
        guard let artifact else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let requested = request.value(forHTTPHeaderField: "Range")
                .flatMap { $0.hasPrefix("bytes=") ? $0.dropFirst(6).split(separator: "-") : nil }
            let start = requested?.first.flatMap { UInt64($0) } ?? 0
            let end = min(requested?.last.flatMap { UInt64($0) } ?? artifact.bytes - 1, artifact.bytes - 1)
            guard start <= end else { throw URLError(.badServerResponse) }
            let input = try FileHandle(forReadingFrom: artifact.file)
            defer { try? input.close() }
            try input.seek(toOffset: start)
            let bytes = try input.read(upToCount: Int(end - start + 1)) ?? Data()
            guard pending?.isCancelled == false else { return }
            var headers = ["Content-Length": "\(bytes.count)", "ETag": "\"\(artifact.sha256)\""]
            if requested != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(artifact.bytes)" }
            let response = HTTPURLResponse(url: url, statusCode: requested == nil ? 200 : 206,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
#endif
