import Foundation

/// Job-local callback validation and bounded diagnostics. Invalid notifications
/// degrade live progress/streaming only: the final manifest still determines
/// conversion success. Never log payloads or decoder errors containing book data.
final class ConversionCallbackBoundary: @unchecked Sendable {
    private struct Envelope: Decodable {
        let jobId: String
        let version: Int?
    }

    private let jobID: String
    private let chapterMap: ReaderConversionChapterMap?
    private let cancelled: @Sendable () -> Bool
    private let diagnostic: @Sendable (String) -> Void
    private let lock = NSLock()
    private var closed = false
    private var reported = Set<String>()

    init(jobID: String, chapterMap: ReaderConversionChapterMap? = nil,
         cancelled: @escaping @Sendable () -> Bool = { false },
         diagnostic: @escaping @Sendable (String) -> Void) {
        self.jobID = jobID
        self.chapterMap = chapterMap
        self.cancelled = cancelled
        self.diagnostic = diagnostic
    }

    func progress(_ payload: Data) -> RustConversionCoordinator.ConversionProgressEvent? {
        decode(payload, kind: "progress")
    }

    func chapter(_ payload: Data) -> RustConversionCoordinator.ChapterCompletionEvent? {
        decode(payload, kind: "chapter")
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }

    private func decode<Event: Decodable>(_ payload: Data, kind: String) -> Event? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { report(kind, "late_callback"); return nil }
        guard !cancelled() else { report(kind, "cancelled"); return nil }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: payload) else {
            report(kind, "invalid_payload"); return nil
        }
        // Existing Rust callbacks are unversioned (the original v1 contract).
        // A future explicit incompatible version must not silently decode as v1.
        let version = envelope.version ?? 1
        guard version == 1 else { report(kind, "unsupported_version", version: version); return nil }
        guard envelope.jobId == jobID else { report(kind, "foreign_job", version: version); return nil }
        let mapped: Data
        do { mapped = try chapterMap?.event(payload) ?? payload }
        catch { report(kind, "chapter_mapping", version: version); return nil }
        do { return try decoder.decode(Event.self, from: mapped) }
        catch { report(kind, "invalid_payload", version: version); return nil }
    }

    /// Called under the job-local lock. Deduplicate by event/reason and cap the
    /// total at eight records, including when a native producer repeats failures.
    private func report(_ kind: String, _ reason: String, version: Int? = nil) {
        let key = kind + ":" + reason
        guard reported.count < 8, reported.insert(key).inserted else { return }
        var record: [String: Any] = ["component": "conversion_callback", "jobID": String(jobID.prefix(128)),
            "event": kind, "reason": reason, "action": "drop_notification"]
        record["version"] = version.map { $0 as Any } ?? "unknown"
        guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        diagnostic(String(decoding: bytes, as: UTF8.self))
    }
}
