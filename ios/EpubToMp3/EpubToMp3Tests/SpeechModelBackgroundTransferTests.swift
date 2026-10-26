#if os(iOS) || os(macOS)
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

private final class ModelTransferURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var response = (status: 200, body: Data(), delay: 0.0)
    private var workItem: DispatchWorkItem?

    static func configure(status: Int, body: Data, delay: TimeInterval = 0) {
        lock.lock()
        response = (status, body, delay)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.response
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(fixture.body.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !fixture.body.isEmpty { client?.urlProtocol(self, didLoad: fixture.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        workItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay, execute: work)
    }

    override func stopLoading() {
        workItem?.cancel()
        workItem = nil
    }
}

private final class ModelTransferEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechModelTransferEvent] = []
    var onEvent: ((SpeechModelTransferEvent) -> Void)?

    func record(_ event: SpeechModelTransferEvent) {
        lock.lock()
        events.append(event)
        let callback = onEvent
        lock.unlock()
        callback?(event)
    }

    func progressValues() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case let .progress(_, bytes) = $0 { return bytes }
            return nil
        }
    }
}

private final class ModelInstallResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var terminalEvent: SpeechModelInstallEvent?
    private var installationError: Error?

    func record(event: SpeechModelInstallEvent) {
        lock.lock()
        terminalEvent = event
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        installationError = error
        lock.unlock()
    }

    func result() -> (SpeechModelInstallEvent?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (terminalEvent, installationError)
    }
}

final class SpeechModelBackgroundTransferTests: XCTestCase {
    func testStructuredFailureRenderingDoesNotExposeRustFilesystemDetails() {
        let event = SpeechModelInstallEvent(
            sequence: 4,
            operationID: "operation-fixture",
            modelID: "model-fixture",
            stage: .failed,
            artifactIndex: nil,
            bytesCompleted: 10,
            bytesTotal: 20,
            failure: .init(
                kind: "checksum_mismatch",
                message: "checksum mismatch at /private/model/path",
                requiredBytes: nil,
                availableBytes: nil
            )
        )

        let rendered = SpeechModelLibraryViewState.empty.installStatus(for: event)

        XCTAssertEqual(rendered, L10n.string("settings.modelInstall.verificationFailed"))
        XCTAssertFalse(rendered.contains("/private/model/path"))
    }

    func testSuccessfulHTTPDownloadMovesTemporaryFileIntoRustInbox() async throws {
        let payload = Data("owned model fixture".utf8)
        ModelTransferURLProtocol.configure(status: 200, body: payload)
        let fixture = makeFixture()
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let completed = expectation(description: "Background transfer completed")
        let recorder = ModelTransferEventRecorder()
        recorder.onEvent = { event in
            if case .downloaded = event { completed.fulfill() }
        }
        transfer.setEventHandler { event, delivered in
            recorder.record(event)
            delivered()
        }

        try transfer.enqueue(url: fixture.url, descriptor: fixture.descriptor)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(try Data(contentsOf: fixture.inbox), payload)
        let progress = recorder.progressValues()
        XCTAssertEqual(progress, progress.sorted())
    }

    func testHTTPFailureDoesNotPublishAnInboxFile() async throws {
        ModelTransferURLProtocol.configure(status: 503, body: Data("unavailable".utf8))
        let fixture = makeFixture()
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let failed = expectation(description: "HTTP failure was reported")
        transfer.setEventHandler { event, delivered in
            defer { delivered() }
            guard case let .failed(_, kind, message) = event else { return }
            XCTAssertEqual(kind, "http_failure")
            XCTAssertEqual(message, "HTTP 503")
            failed.fulfill()
        }

        try transfer.enqueue(url: fixture.url, descriptor: fixture.descriptor)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inbox.path))
    }

    func testProgressIsMonotonicWhenDelegateReceivesRegressedTotals() throws {
        let fixture = makeFixture()
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let recorder = ModelTransferEventRecorder()
        transfer.setEventHandler { event, delivered in
            recorder.record(event)
            delivered()
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: fixture.url)
        task.taskDescription = try SpeechModelBackgroundTransfer.encode(fixture.descriptor)

        transfer.urlSession(
            session, downloadTask: task, didWriteData: 8,
            totalBytesWritten: 8, totalBytesExpectedToWrite: 20
        )
        transfer.urlSession(
            session, downloadTask: task, didWriteData: 0,
            totalBytesWritten: 4, totalBytesExpectedToWrite: 20
        )

        XCTAssertEqual(recorder.progressValues(), [8, 8])
        task.cancel()
        session.invalidateAndCancel()
    }

    func testCancellationAndTaskDescriptionSupportRelaunchIdentity() async throws {
        ModelTransferURLProtocol.configure(status: 200, body: Data("late".utf8), delay: 2)
        let fixture = makeFixture()
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let cancelled = expectation(description: "Cancellation was reported")
        transfer.setEventHandler { event, delivered in
            defer { delivered() }
            if case .cancelled = event { cancelled.fulfill() }
        }

        try transfer.enqueue(url: fixture.url, descriptor: fixture.descriptor)
        let active = await transfer.activeDescriptors()
        XCTAssertEqual(active, [fixture.descriptor])
        transfer.cancel(operationID: fixture.descriptor.operationID)
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testTransferRejectsInsecureURLAndInboxOutsideTheOwnedOperationRoot() async throws {
        let fixture = makeFixture()
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let escaped = SpeechModelTransferDescriptor(
            operationID: fixture.descriptor.operationID,
            modelID: fixture.descriptor.modelID,
            revision: fixture.descriptor.revision,
            modelRoot: fixture.descriptor.modelRoot,
            artifactIndex: fixture.descriptor.artifactIndex,
            expectedBytes: fixture.descriptor.expectedBytes,
            inboxPath: URL(fileURLWithPath: fixture.descriptor.modelRoot)
                .appendingPathComponent("unowned.download").path
        )

        XCTAssertThrowsError(try transfer.enqueue(url: fixture.url, descriptor: escaped))
        XCTAssertThrowsError(try transfer.enqueue(
            url: URL(string: "http://models.test/model.onnx")!,
            descriptor: fixture.descriptor
        ))
        let active = await transfer.activeDescriptors()
        XCTAssertTrue(active.isEmpty)
    }

    #if os(iOS)
    func testBackgroundCompletionSurvivesEventsArrivingBeforeAppDelegateReconnects() async {
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration())
        let session = URLSession(configuration: .ephemeral)
        transfer.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        let completed = expectation(description: "Background completion was retained")

        transfer.reconnectBackgroundSession { completed.fulfill() }

        await fulfillment(of: [completed], timeout: 1)
        session.invalidateAndCancel()
    }
    #endif

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTransferURLProtocol.self]
        return configuration
    }

    private func makeFixture() -> (
        url: URL,
        inbox: URL,
        descriptor: SpeechModelTransferDescriptor
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-model-transfer-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent(".model-fixture.downloads/0.download")
        let descriptor = SpeechModelTransferDescriptor(
            operationID: "operation-fixture",
            modelID: "model-fixture",
            revision: "revision-fixture",
            modelRoot: root.path,
            artifactIndex: 0,
            expectedBytes: 20,
            inboxPath: inbox.path
        )
        return (URL(string: "https://models.test/model.onnx")!, inbox, descriptor)
    }
}

final class SpeechModelInstallCoordinatorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if APP_FOUNDATION_HOST_TESTS
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["APP_FOUNDATION_FFI_LIBRARY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Run apple:foundation:ffi:test for the real model-install coordinator boundary.")
        }
        #endif
    }

    func testInsufficientSpaceIsStructuredAndRenderedWithoutStartingHTTP() async throws {
        let fixture = makeClient(capacity: 0)
        let events = await fixture.client.watchInstall(modelID: "pt_BR-faber-medium")
        var iterator = events.makeAsyncIterator()

        do {
            _ = try await fixture.client.install(modelID: "pt_BR-faber-medium")
            XCTFail("Expected preflight to reject insufficient storage")
        } catch let error as SpeechModelInstallationError {
            guard case let .failure(failure) = error else {
                return XCTFail("Expected a structured preflight failure")
            }
            XCTAssertEqual(failure.kind, "insufficient_space")
            XCTAssertNotNil(failure.requiredBytes)
            XCTAssertEqual(failure.availableBytes, 0)
        }

        let nextEvent = await iterator.next()
        let event = try XCTUnwrap(nextEvent)
        XCTAssertEqual(event.stage, .failed)
        XCTAssertTrue(SpeechModelLibraryViewState.empty.installStatus(for: event)
            .contains(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)))
        let active = await fixture.transfer.activeDescriptors()
        XCTAssertTrue(active.isEmpty)
    }

    func testDuplicateRequestIsRejectedAndCancellationCleansOwnedStaging() async throws {
        ModelTransferURLProtocol.configure(status: 200, body: Data(), delay: 10)
        let fixture = makeClient(capacity: UInt64.max)
        let events = await fixture.client.watchInstall(modelID: "pt_BR-faber-medium")
        var iterator = events.makeAsyncIterator()
        let installing = Task {
            try await fixture.client.install(modelID: "pt_BR-faber-medium")
        }
        let nextEvent = await iterator.next()
        let preflight = try XCTUnwrap(nextEvent)
        XCTAssertEqual(preflight.stage, .preflight)

        do {
            _ = try await fixture.client.install(modelID: "pt_BR-faber-medium")
            XCTFail("Expected duplicate installation rejection")
        } catch let error as SpeechModelInstallationError {
            XCTAssertEqual(error, .duplicate("pt_BR-faber-medium"))
        }

        await fixture.client.cancelInstall(modelID: "pt_BR-faber-medium")
        do {
            _ = try await installing.value
            XCTFail("Expected the original request to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".pt_BR-faber-medium.installing").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".pt_BR-faber-medium.downloads").path
        ))
    }

    func testChecksumMismatchPreservesThePreviousVerifiedModelAndCleansStaging() async throws {
        ModelTransferURLProtocol.configure(status: 200, body: Data("wrong model".utf8))
        let fixture = makeClient(capacity: UInt64.max)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previous = fixture.root.appendingPathComponent("pt_BR-faber-medium", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let marker = previous.appendingPathComponent("previous.marker")
        try Data("previous".utf8).write(to: marker)
        let events = await fixture.client.watchInstall(modelID: "pt_BR-faber-medium")
        let recorder = ModelInstallResultRecorder()
        let terminal = expectation(description: "Terminal install event was observed")
        let installationFinished = expectation(description: "Install request returned")
        let observer = Task {
            for await event in events where !event.isActive {
                recorder.record(event: event)
                terminal.fulfill()
                return
            }
        }
        let installation = Task {
            do {
                _ = try await fixture.client.install(modelID: "pt_BR-faber-medium")
            } catch {
                recorder.record(error: error)
            }
            installationFinished.fulfill()
        }

        await fulfillment(of: [terminal, installationFinished], timeout: 3)
        observer.cancel()
        installation.cancel()
        let (terminalEvent, installationError) = recorder.result()
        let error = try XCTUnwrap(installationError)
        XCTAssertTrue(
            error.localizedDescription.localizedCaseInsensitiveContains("checksum"),
            "Unexpected install error: \(error.localizedDescription)"
        )
        let event = try XCTUnwrap(terminalEvent)
        XCTAssertEqual(event.stage, .failed)
        XCTAssertEqual(event.failure?.kind, "checksum_mismatch")
        XCTAssertEqual(try Data(contentsOf: marker), Data("previous".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".pt_BR-faber-medium.installing").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".pt_BR-faber-medium.downloads").path
        ))
    }

    func testRelaunchResumesOnlyAPersistedCatalogOperation() async throws {
        ModelTransferURLProtocol.configure(status: 200, body: Data(), delay: 10)
        let fixture = makeClient(capacity: UInt64.max)
        let adapter = runtimeAdapter()
        let firstOperationID: String
        do {
            let operation = try adapter.makeModelInstallOperation(
                modelID: "pt_BR-faber-medium",
                root: fixture.root,
                availableBytes: UInt64.max
            )
            firstOperationID = try operation.plan().operationID
        }

        await fixture.client.reconnectPendingTransfers()

        let active = await fixture.transfer.activeDescriptors()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(active.first?.operationID, firstOperationID)
        await fixture.client.cancelInstall(modelID: "pt_BR-faber-medium")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".pt_BR-faber-medium.installing").path
        ))
    }

    private func makeClient(capacity: UInt64) -> (
        client: SpeechModelLibraryClient,
        transfer: SpeechModelBackgroundTransfer,
        root: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-model-client-\(UUID().uuidString)", isDirectory: true)
        let target = SpeechModelLibraryTarget(
            language: "pt-BR",
            platform: "macos",
            androidAPI: 0,
            architecture: "x86_64",
            osVersion: "test",
            modelsRoot: root
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTransferURLProtocol.self]
        let transfer = SpeechModelBackgroundTransfer(configuration: configuration)
        let client = SpeechModelLibraryClient(
            target: target,
            adapter: runtimeAdapter(),
            transfer: transfer,
            availableCapacity: { _ in capacity }
        )
        return (client, transfer, root)
    }

    private func runtimeAdapter() -> ConverterFFIAdapter {
        #if APP_FOUNDATION_HOST_TESTS
        if let path = ProcessInfo.processInfo.environment["APP_FOUNDATION_FFI_LIBRARY"] {
            return ConverterFFIAdapter(libraryURL: URL(fileURLWithPath: path))
        }
        #endif
        return ConverterFFIAdapter()
    }
}
#endif
