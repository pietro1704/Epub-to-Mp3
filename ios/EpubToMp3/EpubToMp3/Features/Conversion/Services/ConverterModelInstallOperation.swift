import Foundation

struct SpeechModelInstallPlan: Decodable, Sendable {
    let version: UInt32
    let operationID: String
    let modelID: String
    let revision: String?
    let requiredBytes: UInt64
    let availableBytes: UInt64
    let ready: Bool
    let artifacts: [Artifact]
    let event: SpeechModelInstallEvent

    enum CodingKeys: String, CodingKey {
        case version, revision, ready, artifacts, event
        case operationID = "operation_id"
        case modelID = "model_id"
        case requiredBytes = "required_bytes"
        case availableBytes = "available_bytes"
    }

    struct Artifact: Decodable, Sendable {
        let index: Int
        let name: String
        let url: URL
        let sha256: String
        let expectedBytes: UInt64
        let inboxPath: URL
        let accepted: Bool

        enum CodingKeys: String, CodingKey {
            case index, name, url, sha256, accepted
            case expectedBytes = "expected_bytes"
            case inboxPath = "inbox_path"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            index = try values.decode(Int.self, forKey: .index)
            name = try values.decode(String.self, forKey: .name)
            url = try values.decode(URL.self, forKey: .url)
            sha256 = try values.decode(String.self, forKey: .sha256)
            expectedBytes = try values.decode(UInt64.self, forKey: .expectedBytes)
            inboxPath = URL(fileURLWithPath: try values.decode(String.self, forKey: .inboxPath))
            accepted = try values.decode(Bool.self, forKey: .accepted)
        }
    }
}

struct SpeechModelInstallEvent: Decodable, Sendable, Equatable {
    enum Stage: String, Decodable, Sendable {
        case preflight, downloading, verifying, publishing, completed, cancelled, failed
    }

    struct Failure: Decodable, Sendable, Equatable {
        let kind: String
        let message: String
        let requiredBytes: UInt64?
        let availableBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case kind, message
            case requiredBytes = "required_bytes"
            case availableBytes = "available_bytes"
        }
    }

    let sequence: UInt64
    let operationID: String
    let modelID: String
    let stage: Stage
    let artifactIndex: Int?
    let bytesCompleted: UInt64
    let bytesTotal: UInt64
    let failure: Failure?

    enum CodingKeys: String, CodingKey {
        case sequence, stage, failure
        case operationID = "operation_id"
        case modelID = "model_id"
        case artifactIndex = "artifact_index"
        case bytesCompleted = "bytes_completed"
        case bytesTotal = "bytes_total"
    }
}

final class ConverterModelInstallOperation: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let planJSON: ConverterModelInstallOperationJSON
    private let eventJSON: ConverterModelInstallOperationJSON
    private let recordProgressFunction: ConverterModelInstallOperationProgress
    private let acceptDownloadFunction: ConverterModelInstallOperationAccept
    private let publishFunction: ConverterModelInstallOperationPublish
    private let failFunction: ConverterModelInstallOperationFail
    private let cancelFunction: ConverterModelInstallOperationCancel
    private let releaseFunction: ConverterModelInstallOperationFree
    private let freeString: ConverterStringFree
    private let lastError: ConverterLastError

    init(
        handle: UnsafeMutableRawPointer,
        planJSON: @escaping ConverterModelInstallOperationJSON,
        eventJSON: @escaping ConverterModelInstallOperationJSON,
        recordProgress: @escaping ConverterModelInstallOperationProgress,
        acceptDownload: @escaping ConverterModelInstallOperationAccept,
        publish: @escaping ConverterModelInstallOperationPublish,
        fail: @escaping ConverterModelInstallOperationFail,
        cancel: @escaping ConverterModelInstallOperationCancel,
        release: @escaping ConverterModelInstallOperationFree,
        freeString: @escaping ConverterStringFree,
        lastError: @escaping ConverterLastError
    ) {
        self.handle = handle
        self.planJSON = planJSON
        self.eventJSON = eventJSON
        self.recordProgressFunction = recordProgress
        self.acceptDownloadFunction = acceptDownload
        self.publishFunction = publish
        self.failFunction = fail
        self.cancelFunction = cancel
        self.releaseFunction = release
        self.freeString = freeString
        self.lastError = lastError
    }

    deinit { releaseFunction(handle) }

    func plan() throws -> SpeechModelInstallPlan {
        try decode(planJSON(handle), as: SpeechModelInstallPlan.self)
    }

    func event() throws -> SpeechModelInstallEvent {
        try decode(eventJSON(handle), as: SpeechModelInstallEvent.self)
    }

    func recordProgress(artifactIndex: Int, downloadedBytes: UInt64) throws {
        guard recordProgressFunction(handle, artifactIndex, downloadedBytes) else {
            throw operationError()
        }
    }

    func accept(artifactIndex: Int, downloadedFile: URL) throws {
        let accepted = downloadedFile.path.withCString {
            acceptDownloadFunction(handle, artifactIndex, $0)
        }
        guard accepted else { throw operationError() }
    }

    func publish() throws -> URL {
        guard let value = publishFunction(handle) else { throw operationError() }
        defer { freeString(value) }
        guard let path = String(validatingCString: value) else { throw operationError() }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func fail(kind: String, message: String) throws {
        let failed = kind.withCString { kindPointer in
            message.withCString { messagePointer in
                failFunction(handle, kindPointer, messagePointer)
            }
        }
        guard failed else { throw operationError() }
    }

    func cancel() { cancelFunction(handle) }

    private func decode<Value: Decodable>(
        _ value: UnsafeMutablePointer<CChar>?,
        as type: Value.Type
    ) throws -> Value {
        guard let value else { throw operationError() }
        defer { freeString(value) }
        guard let json = String(validatingCString: value) else { throw operationError() }
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func operationError() -> EmbeddedConverterError {
        guard let value = lastError() else {
            return .conversionFailed("unknown model install operation error")
        }
        defer { freeString(value) }
        return .conversionFailed(
            String(validatingCString: value) ?? "unknown model install operation error"
        )
    }
}
