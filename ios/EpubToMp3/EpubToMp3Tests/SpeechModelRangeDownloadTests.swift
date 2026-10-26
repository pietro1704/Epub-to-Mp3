#if os(iOS) || os(macOS)
import CryptoKit
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechModelRangeDownloadTests: XCTestCase {
    func testRestartReusesCommittedPrefixAndReconstructsIdenticalFullHash() throws {
        let payload = Data("abcdef".utf8)
        for boundary in 1..<payload.count {
            let fixture = SpeechModelRangeFixture(expectedBytes: UInt64(payload.count))
            defer { fixture.remove() }
            let first = try XCTUnwrap(fixture.download.initialRequest())
            let next = try fixture.acceptPrefix(payload.prefix(boundary), request: first)
            XCTAssertEqual(next.offset, UInt64(boundary))

            // A fresh value uses only persisted bytes, as after process termination.
            let recovered = try XCTUnwrap(fixture.download.initialRequest())
            XCTAssertEqual(recovered.urlRequest.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
            XCTAssertEqual(recovered.offset, UInt64(boundary))
            let outcome = try fixture.accept(
                Data(payload.dropFirst(boundary)), request: recovered,
                headers: ["Content-Range": "bytes \(boundary)-5/6", "ETag": "\"v1\""]
            )
            guard case .complete = outcome else { return XCTFail("Expected full reconstruction") }
            let reconstructed = try Data(contentsOf: fixture.inbox)
            XCTAssertEqual(reconstructed, payload)
            XCTAssertEqual(SHA256.hash(data: reconstructed), SHA256.hash(data: payload))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        }
    }

    func testIgnoredRangeOrChangedIfRangeReplacesPrefixWithFullResponse() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        let next = try fixture.acceptPrefix(Data("abc".utf8))
        let outcome = try fixture.accept(
            Data("abcdef".utf8), request: next, status: 200, headers: ["ETag": "\"v2\""]
        )
        guard case .complete = outcome else { return XCTFail("Expected full replacement") }
        XCTAssertEqual(try Data(contentsOf: fixture.inbox), Data("abcdef".utf8))
    }

    func testChangedValidatorOrInvalidRangeRestartsOnlyOnceWithoutAppending() throws {
        let invalidResponses = [
            ["Content-Range": "bytes 3-5/6", "ETag": "\"v2\""],
            ["Content-Range": "bytes 2-4/6", "ETag": "\"v1\""],
            ["Content-Range": "bytes 3-5/7", "ETag": "\"v1\""],
            ["Content-Range": "bytes */6", "ETag": "\"v1\""],
            ["Content-Range": "bytes 3-5/6", "ETag": "W/\"v1\""],
            ["Content-Range": "bytes 3-5/6"],
            ["Content-Range": "bytes 3-5/6", "ETag": "\"v1\"", "Content-Encoding": "gzip"],
        ]
        for headers in invalidResponses {
            let fixture = SpeechModelRangeFixture(expectedBytes: 6)
            defer { fixture.remove() }
            let previous = try fixture.acceptPrefix(Data("abc".utf8))
            let outcome = try fixture.accept(Data("def".utf8), request: previous, headers: headers)
            guard case let .next(full) = outcome else { return XCTFail("Expected full restart") }
            XCTAssertTrue(full.fullDownload)
            XCTAssertNil(full.urlRequest.value(forHTTPHeaderField: "Range"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
            XCTAssertThrowsError(try fixture.accept(
                Data("def".utf8), request: full, headers: headers
            ))
        }
    }

    func testOversizedAndShortRangeBodiesAnd416RestartFromZero() throws {
        for (status, bytes) in [(206, Data("de".utf8)), (206, Data("defg".utf8)), (416, Data())] {
            let fixture = SpeechModelRangeFixture(expectedBytes: 6)
            defer { fixture.remove() }
            let previous = try fixture.acceptPrefix(Data("abc".utf8))
            let outcome = try fixture.accept(
                bytes, request: previous, status: status,
                headers: ["Content-Range": "bytes 3-5/6", "ETag": "\"v1\""]
            )
            guard case let .next(full) = outcome else { return XCTFail("Expected full restart") }
            XCTAssertTrue(full.fullDownload)
        }
    }

    func testCrashAfterAppendTruncatesUncommittedTailBeforeResume() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        _ = try fixture.acceptPrefix(Data("abc".utf8))
        try Data("abcde".utf8).write(to: fixture.partial)

        let resumed = try XCTUnwrap(fixture.download.initialRequest())

        XCTAssertEqual(resumed.offset, 3)
        XCTAssertEqual(try Data(contentsOf: fixture.partial), Data("abc".utf8))
    }

    func testCrashBeforeFinalRenameRecoversCompleteInboxWithoutNewRequest() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        _ = try fixture.acceptPrefix(Data("abc".utf8))
        try Data("abcdef".utf8).write(to: fixture.partial)
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.receipt)
        ) as? [String: Any])
        receipt["committedBytes"] = 6
        try JSONSerialization.data(withJSONObject: receipt).write(to: fixture.receipt, options: .atomic)

        XCTAssertNil(try fixture.download.initialRequest())
        XCTAssertEqual(try Data(contentsOf: fixture.inbox), Data("abcdef".utf8))
    }

    func testOversizedOrTruncatedPrefixIsDiscarded() throws {
        for payload in [Data("a".utf8), Data("abcdefg".utf8)] {
            let fixture = SpeechModelRangeFixture(expectedBytes: 6)
            defer { fixture.remove() }
            _ = try fixture.acceptPrefix(Data("abc".utf8))
            try payload.write(to: fixture.partial)
            XCTAssertEqual(try fixture.download.initialRequest()?.offset, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        }
    }

    func testStaleOperationRevisionSizeAndSourceURLNeverReuseCheckpoint() throws {
        for changedField in 0..<4 {
            let fixture = SpeechModelRangeFixture(expectedBytes: 6)
            defer { fixture.remove() }
            _ = try fixture.acceptPrefix(Data("abc".utf8))
            let original = fixture.descriptor
            let changed = SpeechModelTransferDescriptor(
                operationID: changedField == 0 ? "different-operation" : original.operationID,
                modelID: original.modelID,
                revision: changedField == 1 ? "different-revision" : original.revision,
                modelRoot: original.modelRoot, artifactIndex: original.artifactIndex,
                expectedBytes: changedField == 2 ? 7 : original.expectedBytes,
                inboxPath: original.inboxPath
            )
            let download = SpeechModelRangeDownload(
                descriptor: changed,
                sourceURL: changedField == 3 ? URL(string: "https://models.test/different")! : fixture.sourceURL
            )
            XCTAssertEqual(try download.initialRequest()?.offset, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        }
    }

    func testRetryPreservesPrefixHasABudgetAndNeverRetriesCancellation() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        var request = try fixture.acceptPrefix(Data("abc".utf8))
        for attempt in 1...SpeechModelRangeDownload.maximumRetries {
            request = try XCTUnwrap(fixture.download.retry(
                after: URLError(.networkConnectionLost), request: request
            ))
            XCTAssertEqual(request.retryCount, attempt)
            XCTAssertEqual(request.offset, 3)
        }
        XCTAssertNil(try fixture.download.retry(after: URLError(.timedOut), request: request))
        XCTAssertNil(try fixture.download.retry(after: URLError(.cancelled), request: request))
        XCTAssertNil(try fixture.download.retry(after: URLError(.serverCertificateUntrusted), request: request))
    }

    func testTaskDescriptionKeepsLegacyIdentityAndRangeState() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        let next = try fixture.acceptPrefix(Data("abc".utf8))
        let encoded = try next.encoded()
        XCTAssertEqual(SpeechModelBackgroundTransfer.decode(encoded), fixture.descriptor)
        XCTAssertEqual(SpeechModelRangeDownload.Request.decode(encoded)?.offset, 3)
        XCTAssertEqual(SpeechModelRangeDownload.Request.decode(encoded)?.validator, "\"v1\"")
        XCTAssertEqual(SpeechModelBackgroundTransfer.decode(
            try SpeechModelBackgroundTransfer.encode(fixture.descriptor)
        ), fixture.descriptor)
    }

    func testCheckpointSymlinkCannotReadOrOverwriteAnUnrelatedArtifact() throws {
        let fixture = SpeechModelRangeFixture(expectedBytes: 6)
        defer { fixture.remove() }
        _ = try fixture.download.initialRequest()
        let unrelated = fixture.root.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: fixture.partial, withDestinationURL: unrelated)
        XCTAssertEqual(try fixture.download.initialRequest()?.offset, 0)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
    }
}

struct SpeechModelRangeFixture {
    let root: URL
    let sourceURL: URL
    let descriptor: SpeechModelTransferDescriptor
    var inbox: URL { URL(fileURLWithPath: descriptor.inboxPath) }
    var partial: URL { inbox.appendingPathExtension("partial") }
    var receipt: URL { inbox.appendingPathExtension("range.json") }
    var download: SpeechModelRangeDownload {
        SpeechModelRangeDownload(descriptor: descriptor, sourceURL: sourceURL)
    }

    init(expectedBytes: UInt64) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-range-\(UUID().uuidString)", isDirectory: true)
        sourceURL = URL(string: "https://models.range.test/\(UUID().uuidString).onnx")!
        descriptor = SpeechModelTransferDescriptor(
            operationID: "operation-v1", modelID: "model", revision: "manifest-v1",
            modelRoot: root.path, artifactIndex: 0, expectedBytes: expectedBytes,
            inboxPath: root.appendingPathComponent(".model.downloads/0.download").path
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func acceptPrefix(
        _ prefix: Data, request: SpeechModelRangeDownload.Request? = nil
    ) throws -> SpeechModelRangeDownload.Request {
        let request = try request ?? XCTUnwrap(download.initialRequest())
        let outcome = try accept(prefix, request: request, headers: [
            "ETag": "\"v1\"",
            "Content-Range": "bytes 0-\(prefix.count - 1)/\(descriptor.expectedBytes)",
        ])
        guard case let .next(next) = outcome else { throw URLError(.badServerResponse) }
        return next
    }

    func accept(
        _ bytes: Data, request: SpeechModelRangeDownload.Request,
        status: Int = 206, headers: [String: String]
    ) throws -> SpeechModelRangeDownload.Outcome {
        let file = root.appendingPathComponent("response-\(UUID().uuidString)")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = HTTPURLResponse(
            url: sourceURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return try download.accept(response: response, file: file, request: request)
    }
}
#endif
