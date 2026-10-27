#if os(iOS) || os(macOS)
import CryptoKit
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Bounded phase-6 proof: tiny local fixtures, no public model or device launch.
final class SpeechModelRangeHTTPTests: XCTestCase {
    func testLoopbackRangesInterruptionValidatorChangeAndRestartProduceIdenticalBytes() async throws {
        let payload = Data(repeating: 0x61, count: Int(SpeechModelRangeDownload.chunkBytes))
            + Data("distinct final range".utf8)
        for scenario in SpeechModelRangeHTTPFixture.Scenario.allCases {
            let server = try SpeechModelRangeHTTPFixture(payload: payload, scenario: scenario)
            defer { server.close() }
            await fulfillment(of: [server.ready], timeout: 3)
            let fixture = SpeechModelRangeFixture(expectedBytes: UInt64(payload.count))
            defer { fixture.remove() }
            SpeechModelRangeLoopbackProtocol.register(
                fixture.sourceURL, destination: try XCTUnwrap(server.url)
            )
            defer { SpeechModelRangeLoopbackProtocol.unregister(fixture.sourceURL) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SpeechModelRangeLoopbackProtocol.self]
            let transfer = SpeechModelBackgroundTransfer(configuration: configuration)
            let completed = expectation(description: "Loopback range scenario \(scenario) completed")
            completed.assertForOverFulfill = true
            transfer.setEventHandler { event, delivered in
                defer { delivered() }
                switch event {
                case .downloaded: completed.fulfill()
                case let .failed(_, kind, message):
                    XCTFail("\(scenario) failed: \(kind): \(message)")
                    completed.fulfill()
                default: break
                }
            }

            try transfer.enqueue(url: fixture.sourceURL, descriptor: fixture.descriptor)
            await fulfillment(of: [completed], timeout: 10)

            let actual = try Data(contentsOf: fixture.inbox)
            XCTAssertEqual(actual, payload, "No duplicated prefix in \(scenario)")
            XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: payload))
            let requests = server.requests
            XCTAssertEqual(requests.first?["range"], "bytes=0-4194303")
            switch scenario {
            case .normal:
                XCTAssertEqual(requests.count, 2)
                XCTAssertEqual(requests.last?["if-range"], "\"v1\"")
            case .interruptOnce:
                XCTAssertEqual(requests.count, 3)
                XCTAssertEqual(requests[1]["range"], requests[2]["range"])
            case .changedValidator, .invalidRange:
                XCTAssertNil(requests.last?["range"], "Invalid range must trigger full replacement")
            case .ignoredRange:
                XCTAssertEqual(requests.count, 1, "A full 200 already contains all bytes")
            }
        }
    }

    func testFreshTransportObjectContinuesThePersistedRangeAfterRelaunch() async throws {
        let payload = Data("abcdef".utf8)
        let server = try SpeechModelRangeHTTPFixture(payload: payload, scenario: .normal)
        defer { server.close() }
        await fulfillment(of: [server.ready], timeout: 3)
        let fixture = SpeechModelRangeFixture(expectedBytes: UInt64(payload.count))
        defer { fixture.remove() }
        _ = try fixture.acceptPrefix(Data(payload.prefix(3)))
        SpeechModelRangeLoopbackProtocol.register(
            fixture.sourceURL, destination: try XCTUnwrap(server.url)
        )
        defer { SpeechModelRangeLoopbackProtocol.unregister(fixture.sourceURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechModelRangeLoopbackProtocol.self]
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration)
        let completed = expectation(description: "Fresh transport recovered committed prefix")
        transfer.setEventHandler { event, delivered in
            defer { delivered() }
            if case .downloaded = event { completed.fulfill() }
        }

        try transfer.enqueue(url: fixture.sourceURL, descriptor: fixture.descriptor)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?["range"], "bytes=3-5")
        XCTAssertEqual(server.requests.first?["if-range"], "\"v1\"")
        XCTAssertEqual(try Data(contentsOf: fixture.inbox), payload)
    }

    func testCancellationBetweenRangesPreservesOnlyTheCommittedPrefixAndItsIdentity() async throws {
        let payload = Data(repeating: 0x62, count: Int(SpeechModelRangeDownload.chunkBytes))
            + Data("uncommitted tail".utf8)
        let server = try SpeechModelRangeHTTPFixture(
            payload: payload, scenario: .normal, pauseAfterFirstRange: true
        )
        defer { server.close() }
        await fulfillment(of: [server.ready], timeout: 3)
        let fixture = SpeechModelRangeFixture(expectedBytes: UInt64(payload.count))
        defer { fixture.remove() }
        SpeechModelRangeLoopbackProtocol.register(
            fixture.sourceURL, destination: try XCTUnwrap(server.url)
        )
        defer { SpeechModelRangeLoopbackProtocol.unregister(fixture.sourceURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechModelRangeLoopbackProtocol.self]
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration)
        let cancelled = expectation(description: "Only the matching operation is cancelled")
        let published = expectation(description: "Cancellation never publishes a complete artifact")
        published.isInverted = true
        transfer.setEventHandler { event, delivered in
            defer { delivered() }
            switch event {
            case let .cancelled(descriptor):
                XCTAssertEqual(descriptor, fixture.descriptor)
                cancelled.fulfill()
            case .downloaded: published.fulfill()
            case let .failed(_, kind, message): XCTFail("Unexpected failure: \(kind): \(message)")
            default: break
            }
        }
        try transfer.enqueue(url: fixture.sourceURL, descriptor: fixture.descriptor)
        await fulfillment(of: [server.pausedRange], timeout: 5)
        let receipt = try Data(contentsOf: fixture.receipt)

        transfer.cancel(operationID: "unrelated-operation")
        let active = await transfer.activeDescriptors()
        XCTAssertEqual(active, [fixture.descriptor])
        transfer.cancel(operationID: fixture.descriptor.operationID)
        await fulfillment(of: [cancelled], timeout: 3)
        await fulfillment(of: [published], timeout: 0.1)

        XCTAssertEqual(server.requests.count, 2, "No next block may start after cancellation")
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data(payload.prefix(Int(SpeechModelRangeDownload.chunkBytes))))
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inbox.path))
    }
}
#endif
