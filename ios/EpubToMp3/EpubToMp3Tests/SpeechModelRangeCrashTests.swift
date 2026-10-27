#if os(macOS)
import CryptoKit
import Darwin
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelRangeCrashTests: XCTestCase {
    func testKilledWriterLeavesOnlyCommittedPrefixReusableByAFreshTransport() async throws {
        let payload = Data("helloworld!".utf8)
        let fixture = SpeechModelRangeFixture(expectedBytes: UInt64(payload.count))
        defer { fixture.remove() }
        _ = try fixture.acceptPrefix(Data(payload.prefix(5)))

        // A separate writer dies after fsync but before publishing a new receipt.
        // No shell, app termination, model download or compiler is involved.
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        writer.arguments = ["-e", #"File.open(ARGV.fetch(0), 'ab') { |f| f.write('wo'); f.flush; f.fsync }; Process.kill('KILL', Process.pid)"#, fixture.partial.path]
        writer.standardOutput = FileHandle.nullDevice
        let watchdog = DispatchWorkItem { if writer.isRunning { writer.terminate() } }
        try writer.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        writer.waitUntilExit()
        watchdog.cancel()
        XCTAssertEqual(writer.terminationReason, .uncaughtSignal)
        XCTAssertEqual(writer.terminationStatus, SIGKILL)
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("hellowo".utf8))

        let server = try SpeechModelRangeHTTPFixture(payload: payload, scenario: .normal)
        defer { server.close() }
        await fulfillment(of: [server.ready], timeout: 3)
        SpeechModelRangeLoopbackProtocol.register(
            fixture.sourceURL, destination: try XCTUnwrap(server.url)
        )
        defer { SpeechModelRangeLoopbackProtocol.unregister(fixture.sourceURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechModelRangeLoopbackProtocol.self]
        let transport = SpeechModelBackgroundTransfer(configuration: configuration)
        let completed = expectation(description: "Fresh transport recovered after writer death")
        transport.setEventHandler { event, delivered in
            defer { delivered() }
            switch event {
            case .downloaded: completed.fulfill()
            case let .failed(_, kind, message):
                XCTFail("Recovery failed: \(kind): \(message)")
                completed.fulfill()
            default: break
            }
        }
        try transport.enqueue(url: fixture.sourceURL, descriptor: fixture.descriptor)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(server.requests.first?["range"], "bytes=5-10")
        XCTAssertEqual(server.requests.first?["if-range"], "\"v1\"")
        let recovered = try Data(contentsOf: fixture.inbox)
        XCTAssertEqual(recovered, payload)
        XCTAssertEqual(SHA256.hash(data: recovered), SHA256.hash(data: payload))
    }
}
#endif
