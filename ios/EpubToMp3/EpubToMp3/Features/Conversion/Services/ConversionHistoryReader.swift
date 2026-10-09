import Foundation

enum ConversionHistoryReader {
    struct EmbeddedSnapshot: Sendable {
        let sessions: [SessionRecord]
        let ioOnMainThread: Bool
    }

    private struct EmbeddedManifestEnvelope: Decodable {
        let manifest: Manifest

        struct Manifest: Decodable {
            let jobId: String
            let title: String
            let chapters: [Chapter]
        }

        struct Chapter: Decodable {}
    }

    struct Snapshot: Sendable {
        let sessions: [SessionRecord]
        let bytesRead: Int
        let budgetExhausted: Bool
        let ioOnMainThread: Bool
    }

    static func readLatest(from url: URL, limit: Int = 100, byteBudget: Int = 1_048_576) throws -> Snapshot {
        guard limit > 0 else { return Snapshot(sessions: [], bytesRead: 0, budgetExhausted: false, ioOnMainThread: false) }
        guard byteBudget > 0 else {
            throw NSError(domain: "ConversionHistoryReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid history read budget."])
        }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        var blocks: [Data] = []
        var bytesRead = 0
        var recordBoundaries = 0
        var lineHasContent = false
        // Read one extra record boundary so the partial leading record can be
        // discarded without decoding a broken UTF-8 scalar or returning old rows.
        while offset > 0 && recordBoundaries <= limit && bytesRead < byteBudget {
            try Task.checkCancellation()
            let count = Int(min(offset, UInt64(min(16_384, byteBudget - bytesRead))))
            offset -= UInt64(count)
            try handle.seek(toOffset: offset)
            let block = try handle.read(upToCount: count) ?? Data()
            guard !block.isEmpty else { break }
            bytesRead += block.count
            for byte in block.reversed() {
                if byte == 10 || byte == 13 {
                    if lineHasContent { recordBoundaries += 1 }
                    lineHasContent = false
                } else {
                    lineHasContent = true
                }
            }
            blocks.append(block)
        }
        var tail = Data(capacity: bytesRead)
        for block in blocks.reversed() { tail.append(block) }
        if offset > 0 {
            if let boundary = tail.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                tail.removeSubrange(tail.startIndex...boundary)
            } else {
                tail.removeAll(keepingCapacity: false)
            }
        }
        let decoder = JSONDecoder()
        try Task.checkCancellation()
        let sessions = Array(tail.split(whereSeparator: { $0 == 10 || $0 == 13 }).suffix(limit).compactMap { line in
            try? decoder.decode(SessionRecord.self, from: Data(line))
        }.reversed())
        try Task.checkCancellation()
        return Snapshot(sessions: sessions, bytesRead: bytesRead,
                        budgetExhausted: offset > 0 && bytesRead >= byteBudget && recordBoundaries <= limit,
                        ioOnMainThread: Thread.isMainThread)
    }

    static func loadLatest(from url: URL, limit: Int = 100) async throws -> Snapshot {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try readLatest(from: url, limit: limit) }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
    }

    static func loadEmbeddedManifests(from root: URL) async throws -> EmbeddedSnapshot {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try readEmbeddedManifests(from: root) }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
    }

    private static func readEmbeddedManifests(from root: URL) throws -> EmbeddedSnapshot {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return EmbeddedSnapshot(sessions: [], ioOnMainThread: Thread.isMainThread)
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var localSessions: [(date: Date, session: SessionRecord)] = []
        let decoder = JSONDecoder()
        for directory in directories {
            try Task.checkCancellation()
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let handle = try? FileHandle(forReadingFrom: manifestURL) else { continue }
            let data: Data
            do {
                data = try handle.read(upToCount: 1_048_577) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                continue
            }
            guard data.count <= 1_048_576,
                  let envelope = try? decoder.decode(EmbeddedManifestEnvelope.self, from: data),
                  !envelope.manifest.chapters.isEmpty else { continue }
            let modifiedAt = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let session = SessionRecord(
                timestamp: ISO8601DateFormatter().string(from: modifiedAt),
                bookTitle: envelope.manifest.title,
                jobId: envelope.manifest.jobId,
                engine: "Rust",
                chaptersConverted: envelope.manifest.chapters.count,
                durationSeconds: nil,
                outcome: "finished",
                mode: "embedded"
            )
            localSessions.append((modifiedAt, session))
        }
        try Task.checkCancellation()
        return EmbeddedSnapshot(
            sessions: localSessions.sorted { $0.date > $1.date }.map(\.session),
            ioOnMainThread: Thread.isMainThread
        )
    }
}
