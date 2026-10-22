import Foundation

/// Serializes disk admission and owns temporary-file lifetime. The coordinator
/// supplies generation/identity validation on both sides of suspension points.
@MainActor
final class PlaybackSegmentPersistence {
    enum Validation: Equatable { case invalid, duplicate, current }
    private let writer: SegmentFileWriter
    /// Temp directory for segment MP3 files written by `enqueueSegment`.
    /// Created lazily; cleaned up in `teardownPlayer()`.
    private(set) var directory: URL?
    private var usesAsyncIO = false
    private var tail: Task<Bool, Never>?
    private var operations: [UUID: Task<Bool, Never>] = [:]
    init(writer: SegmentFileWriter) { self.writer = writer }

    func enqueue(data: Data, identity: SegmentBacklog.Identity,
                 validate: @escaping () -> Validation,
                 prepare: @escaping () async -> Bool,
                 failed: @escaping () -> Void,
                 accept: @escaping (URL) -> Void) async -> Bool {
        guard !Task.isCancelled else { return false }
        let requestID = UUID()
        let previous = tail
        let operation = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self, !Task.isCancelled else { return false }
            switch validate() {
            case .invalid: return false
            case .duplicate: return true
            case .current: break
            }
            guard await prepare(), !Task.isCancelled, validate() != .invalid else { return false }
            let file = self.fileURL(identity: identity)
            self.usesAsyncIO = true
            do {
                try await self.writer.persist(data, to: file)
            } catch {
                if !Task.isCancelled, validate() != .invalid { failed() }
                return false
            }
            guard !Task.isCancelled, validate() != .invalid else {
                await self.writer.remove(file)
                return false
            }
            // A synchronous compatibility call may have accepted this identity
            // while persistence was suspended. Preserve the original URL.
            if validate() == .duplicate {
                await self.writer.remove(file)
                return true
            }
            accept(file)
            return true
        }
        tail = operation
        operations[requestID] = operation
        let accepted = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        operations.removeValue(forKey: requestID)
        if operations.isEmpty { tail = nil }
        return accepted
    }

    func writeSynchronously(_ data: Data, identity: SegmentBacklog.Identity) throws -> URL {
        let file = fileURL(identity: identity)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
    func remove(_ file: URL) { Task { await writer.remove(file) } }
    func cancelOperations() {
        for operation in operations.values { operation.cancel() }
        tail = nil
    }
    func removeDirectory() {
        // A segment is retained until insertion or session teardown. The
        // coordinator detaches AVURLAssets before this intentional discard.
        if let directory {
            if usesAsyncIO { Task { await writer.remove(directory) } }
            else { try? FileManager.default.removeItem(at: directory) }
            self.directory = nil
        }
        usesAsyncIO = false
    }
    private func fileURL(identity: SegmentBacklog.Identity) -> URL {
        let directory = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("epub2mp3-segments-\(UUID().uuidString)")
        self.directory = directory
        return directory.appendingPathComponent(
            "stream-\(UUID().uuidString)-ch\(identity.chapterIndex)-seg\(identity.segmentIndex)-\(UUID().uuidString).mp3"
        )
    }
}
