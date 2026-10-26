import Foundation

struct SpeechModelTransferDescriptor: Codable, Equatable, Sendable {
    let operationID: String
    let modelID: String
    let revision: String?
    let modelRoot: String
    let artifactIndex: Int
    let expectedBytes: UInt64
    let inboxPath: String

    enum CodingKeys: String, CodingKey {
        case revision
        case operationID = "operation_id"
        case modelID = "model_id"
        case modelRoot = "model_root"
        case artifactIndex = "artifact_index"
        case expectedBytes = "expected_bytes"
        case inboxPath = "inbox_path"
    }

    func validatedInboxURL() throws -> URL {
        guard !modelID.isEmpty,
              modelID != ".", modelID != "..",
              !modelID.contains("/"), !modelID.contains("\\"),
              artifactIndex >= 0 else {
            throw URLError(.badURL)
        }
        let root = URL(fileURLWithPath: modelRoot, isDirectory: true).standardizedFileURL
        let expected = root
            .appendingPathComponent(".\(modelID).downloads", isDirectory: true)
            .appendingPathComponent("\(artifactIndex).download", isDirectory: false)
            .standardizedFileURL
        let declared = URL(fileURLWithPath: inboxPath, isDirectory: false).standardizedFileURL
        guard declared == expected else { throw URLError(.noPermissionsToReadFile) }
        return expected
    }
}

enum SpeechModelTransferEvent: Sendable {
    case progress(SpeechModelTransferDescriptor, UInt64)
    case downloaded(SpeechModelTransferDescriptor)
    case failed(SpeechModelTransferDescriptor, kind: String, message: String)
    case cancelled(SpeechModelTransferDescriptor)
}

/// Apple owns background HTTP transport; Rust owns validation and publication.
final class SpeechModelBackgroundTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SpeechModelBackgroundTransfer()
    static let backgroundSessionIdentifier = "com.pietrocode.epubtomp3.speech-models"

    typealias EventHandler = @Sendable (
        SpeechModelTransferEvent,
        @escaping @Sendable () -> Void
    ) -> Void

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var eventHandler: EventHandler?
    private var bufferedEvents: [SpeechModelTransferEvent] = []
    private var terminalTasks: Set<Int> = []
    private var reportedBytes: [Int: UInt64] = [:]
    private var cancelledOperations: Set<String> = []
    private var backgroundCompletionHandler: (() -> Void)?
    private var backgroundEventsFinished = false
    private var pendingEventDeliveries = 0
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    override convenience init() {
        self.init(configuration: Self.backgroundConfiguration())
    }

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    static func backgroundConfiguration() -> URLSessionConfiguration {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: backgroundSessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        lock.lock()
        eventHandler = handler
        let pending = bufferedEvents
        bufferedEvents.removeAll()
        pendingEventDeliveries += pending.count
        lock.unlock()
        pending.forEach { deliverRegistered($0, to: handler) }
    }

    func enqueue(url: URL, descriptor: SpeechModelTransferDescriptor) throws {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.secureConnectionFailed) }
        _ = try descriptor.validatedInboxURL()
        let download = SpeechModelRangeDownload(descriptor: descriptor, sourceURL: url)
        let initialRequest: SpeechModelRangeDownload.Request?
        do {
            lock.lock()
            defer { lock.unlock() }
            cancelledOperations.remove(descriptor.operationID)
            initialRequest = try download.initialRequest()
        }
        if let request = initialRequest {
            try start(request)
        } else {
            emit(.downloaded(descriptor))
        }
    }

    private func start(_ request: SpeechModelRangeDownload.Request) throws {
        let description = try request.encoded()
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledOperations.contains(request.descriptor.operationID) else { return }
        let task = session.downloadTask(with: request.urlRequest)
        task.taskDescription = description
        task.resume()
    }

    func activeDescriptors() async -> [SpeechModelTransferDescriptor] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap(Self.descriptor(for:)))
            }
        }
    }

    func cancel(operationID: String) {
        lock.lock()
        cancelledOperations.insert(operationID)
        lock.unlock()
        session.getAllTasks { tasks in
            for task in tasks where Self.descriptor(for: task)?.operationID == operationID {
                task.cancel()
            }
        }
    }

    #if os(iOS)
    func reconnectBackgroundSession(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        let completion = takeBackgroundCompletionIfReady()
        lock.unlock()
        _ = session
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
    #endif

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = Self.descriptor(for: downloadTask) else { return }
        let offset = min(
            SpeechModelRangeDownload.Request.decode(downloadTask.taskDescription)?.offset ?? 0,
            descriptor.expectedBytes
        )
        let written = UInt64(max(0, totalBytesWritten))
        let reported = offset + min(written, descriptor.expectedBytes - offset)
        lock.lock()
        let monotonic = max(reportedBytes[downloadTask.taskIdentifier] ?? 0, reported)
        reportedBytes[downloadTask.taskIdentifier] = monotonic
        lock.unlock()
        emit(.progress(descriptor, monotonic))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let descriptor = Self.descriptor(for: downloadTask) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finishTask(downloadTask.taskIdentifier)
            emit(.failed(
                descriptor,
                kind: "http_failure",
                message: "HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)"
            ))
            return
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            finishTask(downloadTask.taskIdentifier)
            emit(.failed(
                descriptor,
                kind: "insecure_redirect",
                message: "Model download redirected outside HTTPS"
            ))
            return
        }
        do {
            let outcome = try accept(location, response: response, task: downloadTask, descriptor: descriptor)
            finishTask(downloadTask.taskIdentifier)
            switch outcome {
            case let .next(request): try start(request)
            case .complete: emit(.downloaded(descriptor))
            case .none: break
            }
        } catch {
            finishTask(downloadTask.taskIdentifier)
            let kind = (200..<300).contains(response.statusCode)
                ? "transport_write_failed" : "http_failure"
            let message = kind == "http_failure" ? "HTTP \(response.statusCode)" : error.localizedDescription
            emit(.failed(descriptor, kind: kind, message: message))
        }
    }

    private func accept(
        _ file: URL, response: HTTPURLResponse, task: URLSessionDownloadTask,
        descriptor: SpeechModelTransferDescriptor
    ) throws -> SpeechModelRangeDownload.Outcome? {
        // Cancellation must finish its transport write before Rust removes the inbox.
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledOperations.contains(descriptor.operationID) else { return nil }
        let request = SpeechModelRangeDownload.Request.decode(task.taskDescription)
            ?? task.originalRequest?.url.map {
                SpeechModelRangeDownload.Request(
                    descriptor: descriptor, sourceURL: $0, offset: 0,
                    validator: nil, fullDownload: true, retryCount: 0
                )
            }
        guard let request else { throw URLError(.badURL) }
        return try SpeechModelRangeDownload(descriptor: descriptor, sourceURL: request.sourceURL)
            .accept(response: response, file: file, request: request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let descriptor = Self.descriptor(for: task) else { return }
        lock.lock()
        // Download callbacks precede this final callback. Retain suppression only
        // until completion, rather than accumulating an ID for every range forever.
        let alreadyTerminal = terminalTasks.remove(task.taskIdentifier) != nil
        reportedBytes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let error, !alreadyTerminal else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            emit(.cancelled(descriptor))
        } else {
            do {
                if let previous = SpeechModelRangeDownload.Request.decode(task.taskDescription),
                   let next = try retry(error, request: previous) {
                    try start(next)
                    return
                }
            } catch {
                emit(.failed(descriptor, kind: "transport_write_failed", message: error.localizedDescription))
                return
            }
            emit(.failed(descriptor, kind: "transport_failed", message: error.localizedDescription))
        }
    }

    private func retry(
        _ error: Error, request: SpeechModelRangeDownload.Request
    ) throws -> SpeechModelRangeDownload.Request? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledOperations.contains(request.descriptor.operationID) else { return nil }
        return try SpeechModelRangeDownload(descriptor: request.descriptor, sourceURL: request.sourceURL)
            .retry(after: error, request: request)
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        backgroundEventsFinished = true
        let completion = takeBackgroundCompletionIfReady()
        lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
    #endif

    static func encode(_ descriptor: SpeechModelTransferDescriptor) throws -> String {
        let bytes = try JSONEncoder().encode(descriptor)
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode(_ value: String?) -> SpeechModelTransferDescriptor? {
        guard let value else { return nil }
        if let request = SpeechModelRangeDownload.Request.decode(value) { return request.descriptor }
        return try? JSONDecoder().decode(
            SpeechModelTransferDescriptor.self,
            from: Data(value.utf8)
        )
    }

    private static func descriptor(for task: URLSessionTask) -> SpeechModelTransferDescriptor? {
        decode(task.taskDescription)
    }

    private func finishTask(_ identifier: Int) {
        lock.lock()
        terminalTasks.insert(identifier)
        reportedBytes.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func emit(_ event: SpeechModelTransferEvent) {
        lock.lock()
        guard let eventHandler else {
            bufferedEvents.append(event)
            lock.unlock()
            return
        }
        pendingEventDeliveries += 1
        lock.unlock()
        deliverRegistered(event, to: eventHandler)
    }

    private func deliverRegistered(
        _ event: SpeechModelTransferEvent,
        to handler: @escaping EventHandler
    ) {
        handler(event) { [weak self] in self?.finishedDeliveringEvent() }
    }

    private func finishedDeliveringEvent() {
        lock.lock()
        pendingEventDeliveries = max(0, pendingEventDeliveries - 1)
        let completion = takeBackgroundCompletionIfReady()
        lock.unlock()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    private func takeBackgroundCompletionIfReady() -> (() -> Void)? {
        guard backgroundEventsFinished,
              pendingEventDeliveries == 0,
              bufferedEvents.isEmpty,
              let completion = backgroundCompletionHandler else { return nil }
        backgroundEventsFinished = false
        backgroundCompletionHandler = nil
        return completion
    }
}
