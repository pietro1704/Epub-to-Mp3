import Foundation

/// Serializes access to one converter binding and keeps filesystem inspection off MainActor.
actor SpeechModelLibraryClient {
    static let shared = SpeechModelLibraryClient()

    nonisolated let initialSnapshot: SpeechModelSnapshot?

    private let adapter: ConverterFFIAdapter?
    private let target: SpeechModelLibraryTarget
    private let transfer: SpeechModelBackgroundTransfer?
    private let availableCapacity: @Sendable (URL) throws -> UInt64
    private let snapshotOverride: (() throws -> SpeechModelSnapshot)?
    private let installOverride: ((String, String) throws -> URL)?
    private var active: [String: ActiveInstall] = [:]
    private var installIntents: Set<String> = []
    private var terminalOperationIDs: Set<String> = []
    private var lastEvents: [String: SpeechModelInstallEvent] = [:]
    private var observers: [String: [UUID: AsyncStream<SpeechModelInstallEvent>.Continuation]] = [:]
    private var observesTransfer = false

    private struct ActiveInstall {
        let operation: ConverterModelInstallOperation
        var plan: SpeechModelInstallPlan
        var completion: CheckedContinuation<URL, Error>?
        var reportedBytes: [Int: UInt64] = [:]
    }

    init(
        target: SpeechModelLibraryTarget = .current(),
        adapter: ConverterFFIAdapter = ConverterFFIAdapter(),
        transfer: SpeechModelBackgroundTransfer = .shared,
        availableCapacity: @escaping @Sendable (URL) throws -> UInt64 = {
            try SpeechModelLibraryClient.volumeCapacity($0)
        }
    ) {
        self.target = target
        self.adapter = adapter
        self.transfer = transfer
        self.availableCapacity = availableCapacity
        self.snapshotOverride = nil
        self.installOverride = nil
        self.initialSnapshot = nil
    }

    init(
        initialSnapshot: SpeechModelSnapshot,
        loadSnapshot: (() throws -> SpeechModelSnapshot)? = nil,
        install: ((String, String) throws -> URL)? = nil,
        target: SpeechModelLibraryTarget = .current()
    ) {
        self.target = target
        self.adapter = nil
        self.transfer = nil
        self.availableCapacity = { try SpeechModelLibraryClient.volumeCapacity($0) }
        self.snapshotOverride = loadSnapshot ?? { initialSnapshot }
        self.installOverride = install
        self.initialSnapshot = initialSnapshot
    }

    func snapshot() throws -> SpeechModelSnapshot {
        if let snapshotOverride { return try snapshotOverride() }
        guard let adapter else { throw EmbeddedConverterError.artifactUnavailable }
        return try adapter.speechModelSnapshot(target: target)
    }

    func watchInstall(modelID: String) -> AsyncStream<SpeechModelInstallEvent> {
        observeTransferIfNeeded()
        let last = lastEvents[modelID]
        return AsyncStream { continuation in
            let identifier = UUID()
            observers[modelID, default: [:]][identifier] = continuation
            if let last { continuation.yield(last) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(modelID: modelID, identifier: identifier) }
            }
        }
    }

    func install(modelID: String) async throws -> URL {
        if let installOverride { return try installOverride(modelID, target.modelsRoot.path) }
        observeTransferIfNeeded()
        guard active[modelID] == nil, !installIntents.contains(modelID) else {
            throw SpeechModelInstallationError.duplicate(modelID)
        }
        installIntents.insert(modelID)
        defer { installIntents.remove(modelID) }
        guard let adapter, let transfer else { throw EmbeddedConverterError.artifactUnavailable }
        if let pending = await transfer.activeDescriptors().first(where: { $0.modelID == modelID }) {
            _ = try recoverOperation(for: pending)
            throw SpeechModelInstallationError.duplicate(modelID)
        }
        try FileManager.default.createDirectory(at: target.modelsRoot, withIntermediateDirectories: true)
        let capacity = try availableCapacity(target.modelsRoot)
        let operation = try adapter.makeModelInstallOperation(
            modelID: modelID,
            root: target.modelsRoot,
            availableBytes: capacity
        )
        let plan = try operation.plan()
        terminalOperationIDs.remove(plan.operationID)
        emit(plan.event)
        guard plan.ready else {
            throw SpeechModelInstallationError.failure(
                plan.event.failure ?? .init(
                    kind: "preflight_failed", message: "Model installation preflight failed",
                    requiredBytes: plan.requiredBytes, availableBytes: plan.availableBytes
                )
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                active[modelID] = ActiveInstall(
                    operation: operation,
                    plan: plan,
                    completion: continuation,
                    reportedBytes: [:]
                )
                do {
                    if plan.artifacts.allSatisfy(\.accepted) {
                        try complete(modelID: modelID)
                    } else {
                        try enqueueNextArtifact(plan, using: transfer)
                    }
                } catch {
                    fail(modelID: modelID, kind: "transport_start_failed", error: error)
                }
            }
        } onCancel: {
            Task { await self.cancelInstall(modelID: modelID) }
        }
    }

    func cancelInstall(modelID: String) {
        guard let installation = active[modelID] else { return }
        transfer?.cancel(operationID: installation.plan.operationID)
        installation.operation.cancel()
        if let event = try? installation.operation.event() { emit(event) }
        finish(modelID: modelID, result: .failure(CancellationError()))
    }

    func reconnectPendingTransfers() async {
        observeTransferIfNeeded()
        guard let adapter, let transfer else { return }
        let descriptors = await transfer.activeDescriptors()
        let modelsWithActiveTransfers = Set(descriptors.map(\.modelID))
        for descriptor in descriptors {
            do {
                _ = try recoverOperation(for: descriptor)
            } catch {
                transfer.cancel(operationID: descriptor.operationID)
            }
        }
        guard let recoveredSnapshot = try? adapter.speechModelSnapshot(target: target) else { return }
        for entry in recoveredSnapshot.entries
            where entry.distribution.installable
                && !modelsWithActiveTransfers.contains(entry.identity.modelID) {
            do {
                try resumeDormantOperation(
                    modelID: entry.identity.modelID,
                    adapter: adapter,
                    transfer: transfer
                )
            } catch {
                fail(modelID: entry.identity.modelID, kind: "recovery_failed", error: error)
            }
        }
    }

    private func enqueueNextArtifact(
        _ plan: SpeechModelInstallPlan,
        using transfer: SpeechModelBackgroundTransfer
    ) throws {
        guard let artifact = plan.artifacts.first(where: { !$0.accepted }) else { return }
        let descriptor = SpeechModelTransferDescriptor(
            operationID: plan.operationID,
            modelID: plan.modelID,
            revision: plan.revision,
            modelRoot: target.modelsRoot.path,
            artifactIndex: artifact.index,
            expectedBytes: artifact.expectedBytes,
            inboxPath: artifact.inboxPath.path
        )
        try transfer.enqueue(url: artifact.url, descriptor: descriptor)
    }

    private func receive(_ transferEvent: SpeechModelTransferEvent) {
        let descriptor: SpeechModelTransferDescriptor
        switch transferEvent {
        case let .progress(value, _), let .downloaded(value),
             let .failed(value, _, _), let .cancelled(value):
            descriptor = value
        }
        guard !terminalOperationIDs.contains(descriptor.operationID) else { return }
        do {
            let installation = try recoverOperation(for: descriptor)
            switch transferEvent {
            case let .progress(_, bytes):
                let previous = active[descriptor.modelID]?.reportedBytes[descriptor.artifactIndex] ?? 0
                let monotonicBytes = max(previous, min(bytes, descriptor.expectedBytes))
                active[descriptor.modelID]?.reportedBytes[descriptor.artifactIndex] = monotonicBytes
                try installation.operation.recordProgress(
                    artifactIndex: descriptor.artifactIndex,
                    downloadedBytes: monotonicBytes
                )
                emit(try installation.operation.event())
            case .downloaded:
                try installation.operation.accept(
                    artifactIndex: descriptor.artifactIndex,
                    downloadedFile: URL(fileURLWithPath: descriptor.inboxPath)
                )
                let refreshedPlan = try installation.operation.plan()
                active[descriptor.modelID]?.plan = refreshedPlan
                emit(try installation.operation.event())
                if refreshedPlan.artifacts.allSatisfy(\.accepted) {
                    try complete(modelID: descriptor.modelID)
                } else if let transfer {
                    try enqueueNextArtifact(refreshedPlan, using: transfer)
                }
            case let .failed(_, kind, message):
                try installation.operation.fail(kind: kind, message: message)
                emit(try installation.operation.event())
                finish(
                    modelID: descriptor.modelID,
                    result: .failure(SpeechModelInstallationError.transport(message))
                )
            case .cancelled:
                installation.operation.cancel()
                emit(try installation.operation.event())
                finish(modelID: descriptor.modelID, result: .failure(CancellationError()))
            }
        } catch {
            fail(modelID: descriptor.modelID, kind: "operation_failed", error: error)
        }
    }

    private func recoverOperation(
        for descriptor: SpeechModelTransferDescriptor
    ) throws -> ActiveInstall {
        let inbox = try descriptor.validatedInboxURL()
        guard URL(fileURLWithPath: descriptor.modelRoot).standardizedFileURL
            == target.modelsRoot.standardizedFileURL else {
            throw SpeechModelInstallationError.transport("Background task has an unexpected model root")
        }
        if let installation = active[descriptor.modelID] {
            guard installation.plan.operationID == descriptor.operationID,
                  installation.plan.revision == descriptor.revision,
                  let artifact = installation.plan.artifacts.first(where: {
                      $0.index == descriptor.artifactIndex
                  }),
                  artifact.expectedBytes == descriptor.expectedBytes,
                  artifact.inboxPath.standardizedFileURL == inbox,
                  !artifact.accepted else {
                throw SpeechModelInstallationError.transport(
                    "Background task identity no longer matches the active operation"
                )
            }
            return installation
        }
        guard let adapter else { throw EmbeddedConverterError.artifactUnavailable }
        try FileManager.default.createDirectory(at: target.modelsRoot, withIntermediateDirectories: true)
        guard let operation = try adapter.recoverModelInstallOperation(
            modelID: descriptor.modelID,
            root: target.modelsRoot,
            availableBytes: try availableCapacity(target.modelsRoot)
        ) else {
            throw SpeechModelInstallationError.transport("Background task has no matching install receipt")
        }
        let plan = try operation.plan()
        guard plan.operationID == descriptor.operationID,
              plan.modelID == descriptor.modelID,
              plan.revision == descriptor.revision,
              let artifact = plan.artifacts.first(where: { $0.index == descriptor.artifactIndex }),
              artifact.expectedBytes == descriptor.expectedBytes,
              artifact.inboxPath.standardizedFileURL == inbox,
              !artifact.accepted else {
            throw SpeechModelInstallationError.transport("Background task identity no longer matches the catalog")
        }
        emit(plan.event)
        guard plan.ready else {
            throw SpeechModelInstallationError.failure(
                plan.event.failure ?? .init(
                    kind: "preflight_failed", message: "Model installation preflight failed",
                    requiredBytes: plan.requiredBytes, availableBytes: plan.availableBytes
                )
            )
        }
        let installation = ActiveInstall(
            operation: operation,
            plan: plan,
            completion: nil,
            reportedBytes: [:]
        )
        active[descriptor.modelID] = installation
        return installation
    }

    private func resumeDormantOperation(
        modelID: String,
        adapter: ConverterFFIAdapter,
        transfer: SpeechModelBackgroundTransfer
    ) throws {
        guard active[modelID] == nil,
              let operation = try adapter.recoverModelInstallOperation(
                  modelID: modelID,
                  root: target.modelsRoot,
                  availableBytes: try availableCapacity(target.modelsRoot)
              ) else { return }
        var plan = try operation.plan()
        terminalOperationIDs.remove(plan.operationID)
        emit(plan.event)
        guard plan.ready else { return }
        active[modelID] = ActiveInstall(
            operation: operation,
            plan: plan,
            completion: nil,
            reportedBytes: [:]
        )

        while let artifact = plan.artifacts.first(where: { !$0.accepted }),
              FileManager.default.fileExists(atPath: artifact.inboxPath.path) {
            try operation.accept(
                artifactIndex: artifact.index,
                downloadedFile: artifact.inboxPath
            )
            plan = try operation.plan()
            active[modelID]?.plan = plan
            emit(try operation.event())
        }
        if plan.artifacts.allSatisfy(\.accepted) {
            try complete(modelID: modelID)
        } else {
            try enqueueNextArtifact(plan, using: transfer)
        }
    }

    private func complete(modelID: String) throws {
        guard let installation = active[modelID] else { return }
        let installedURL = try installation.operation.publish()
        emit(try installation.operation.event())
        finish(modelID: modelID, result: .success(installedURL))
    }

    private func fail(modelID: String, kind: String, error: Error) {
        guard let installation = active[modelID] else { return }
        try? installation.operation.fail(kind: kind, message: error.localizedDescription)
        if let event = try? installation.operation.event() { emit(event) }
        finish(modelID: modelID, result: .failure(error))
    }

    private func finish(modelID: String, result: Result<URL, Error>) {
        guard let installation = active.removeValue(forKey: modelID) else { return }
        terminalOperationIDs.insert(installation.plan.operationID)
        installation.completion?.resume(with: result)
    }

    private func observeTransferIfNeeded() {
        guard !observesTransfer, let transfer else { return }
        observesTransfer = true
        transfer.setEventHandler { [weak self] event, delivered in
            Task {
                await self?.receive(event)
                delivered()
            }
        }
    }

    private func emit(_ event: SpeechModelInstallEvent) {
        if let previous = lastEvents[event.modelID],
           previous.operationID == event.operationID,
           event.sequence < previous.sequence {
            return
        }
        lastEvents[event.modelID] = event
        for observer in observers[event.modelID]?.values ?? [:].values {
            observer.yield(event)
        }
    }

    private func removeObserver(modelID: String, identifier: UUID) {
        observers[modelID]?.removeValue(forKey: identifier)
    }

    nonisolated static func volumeCapacity(_ root: URL) throws -> UInt64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw SpeechModelInstallationError.transport("Available storage could not be determined")
        }
        return UInt64(capacity)
    }
}
