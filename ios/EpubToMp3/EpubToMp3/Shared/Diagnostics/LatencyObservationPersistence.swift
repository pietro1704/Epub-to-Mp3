import Foundation

/// Owns bounded local diagnostic bytes. No network or listener content enters
/// this seam. One live store owns each persistence instance and its revisions.
final class LatencyObservationPersistence: @unchecked Sendable {
    static let maximumBytes = 512 * 1024
    static let maximumJourneys = 200

    private struct Envelope: Codable {
        let version: Int
        let journeys: [LatencyObservation.Journey]
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.epubtomp3.latency-persistence", qos: .utility)
    private let lock = NSLock()
    private var newestRevision: UInt64 = 0
    private var pending: [LatencyObservation.Journey]?
    private var workerScheduled = false

    init(fileURL: URL) { self.fileURL = fileURL }

    static func applicationStorage() -> LatencyObservationPersistence? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return LatencyObservationPersistence(fileURL: root
            .appendingPathComponent("EpubToMp3/Diagnostics", isDirectory: true)
            .appendingPathComponent("latency-observations.json"))
    }

    /// Hydration precedes all persistence work on this queue. The owner may
    /// collect live events meanwhile, but only submits a snapshot after merging.
    func load(_ completion: @escaping @Sendable ([LatencyObservation.Journey]) -> Void) {
        queue.async { [self] in completion(readArchive()) }
    }

    private func readArchive() -> [LatencyObservation.Journey] {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { return [] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1,
                  envelope.journeys.count <= Self.maximumJourneys,
                  Set(envelope.journeys.map(\.id)).count == envelope.journeys.count,
                  envelope.journeys.allSatisfy(Self.isValidArchive) else { return [] }
            return envelope.journeys
        } catch {
            return []
        }
    }

    /// Called under the owning store's lock; encoding and disk work are deferred.
    func schedule(_ journeys: [LatencyObservation.Journey], revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard revision > newestRevision else { return }
        newestRevision = revision
        pending = Array(journeys.suffix(Self.maximumJourneys))
        guard !workerScheduled else { return }
        workerScheduled = true
        queue.async { [self] in drain() }
    }

    /// Includes all snapshots submitted before this call, including coalesced work.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Hydration can schedule its first drain behind this barrier.
                // Drain its merged snapshot here before declaring flush complete.
                drain()
                continuation.resume()
            }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            write(snapshot)
        }
    }

    private func write(_ journeys: [LatencyObservation.Journey]) {
        do {
            var retained = journeys
            var data = try JSONEncoder().encode(Envelope(version: 1, journeys: retained))
            while data.count > Self.maximumBytes, !retained.isEmpty {
                retained.removeFirst()
                data = try JSONEncoder().encode(Envelope(version: 1, journeys: retained))
            }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = true
            try directoryURL.setResourceValues(flags)
            try data.write(to: fileURL, options: .atomic)
            var artifactURL = fileURL
            try artifactURL.setResourceValues(flags)
        } catch {
            // Diagnostics must never interrupt reading or playback. A later
            // mutation retries persistence; the live snapshot remains usable.
        }
    }

    private static func isValidArchive(_ journey: LatencyObservation.Journey) -> Bool {
        guard !journey.records.isEmpty, journey.records.count <= 5,
              journey.records.first?.elapsedNanoseconds == 0 else { return false }
        if let request = journey.streamRequest {
            guard request.journeyID == journey.id,
                  journey.streamPublication.map({ $0.publicationID == request.publicationID }) ?? true
            else { return false }
        }
        var previous: UInt64 = 0
        var seen = Set<LatencyObservation.Transition>()
        for record in journey.records {
            guard record.elapsedNanoseconds >= previous,
                  !seen.contains(record.transition), !seen.contains(.cancelled) else { return false }
            previous = record.elapsedNanoseconds
            seen.insert(record.transition)
        }
        let initial: LatencyObservation.Transition
        let allowed: Set<LatencyObservation.Transition>
        switch journey.kind {
        case .bookOpen:
            guard journey.streamPublication == nil, journey.streamRequest == nil else { return false }
            initial = .openRequested
            allowed = [.openRequested, .readableContent, .controlsUsable, .firstPDFPage, .cancelled]
        case .progressivePlayback:
            initial = .playRequested
            allowed = [.playRequested, .audioQueued, .audioAudible, .cancelled]
            if let audible = journey.records.firstIndex(where: { $0.transition == .audioAudible }) {
                guard let queued = journey.records.firstIndex(where: { $0.transition == .audioQueued }),
                      queued < audible else { return false }
            }
        case .seek:
            initial = .seekRequested
            allowed = [.seekRequested, .seekTargetReached, .cancelled]
        }
        return journey.records.first?.transition == initial && seen.isSubset(of: allowed)
    }
}
