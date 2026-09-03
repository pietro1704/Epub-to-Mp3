import Dispatch
import Foundation

enum LatencyObservation {
    enum JourneyKind: String, Codable, Equatable {
        case bookOpen = "book_open"
        case progressivePlayback = "progressive_playback"
        case seek
    }

    enum Transition: String, Codable, Equatable {
        case openRequested = "open_requested"
        case readableContent = "readable_content"
        case controlsUsable = "controls_usable"
        case firstPDFPage = "first_pdf_page"
        case playRequested = "play_requested"
        case audioQueued = "audio_queued"
        case audioAudible = "audio_audible"
        case seekRequested = "seek_requested"
        case seekTargetReached = "seek_target_reached"
        case cancelled
    }

    enum DocumentKind: String, Codable, Equatable {
        case epub
        case selectableTextPDF = "selectable_text_pdf"
        case normalizedScannedPDF = "normalized_scanned_pdf"
    }

    enum CacheClass: String, Codable, Equatable {
        case unknown
        case inMemoryWarm = "in_memory_warm"
        case preparedDisk = "prepared_disk"
        case cold
    }

    struct Context: Codable, Equatable {
        let documentKind: DocumentKind
        var cacheClass: CacheClass
    }

    struct Record: Codable, Equatable {
        let transition: Transition
        let elapsedNanoseconds: UInt64
    }

    struct Journey: Codable, Equatable {
        let id: UUID
        let kind: JourneyKind
        var context: Context
        var records: [Record]
    }
}

/// Holds privacy-safe, in-memory timing observations until the listener
/// explicitly exports diagnostics. Book content and identity never enter this
/// boundary: records retain only a random journey identifier, document class,
/// cache class, transition, and monotonic elapsed time.
final class LatencyObservationStore {
    typealias Clock = () -> UInt64

    static let shared = LatencyObservationStore()

    private struct ActiveJourney {
        let startedAtNanoseconds: UInt64
        var journey: LatencyObservation.Journey
        var isTerminal = false
    }

    private let clock: Clock
    private let capacity: Int
    private let lock = NSLock()
    private var activeJourneys: [UUID: ActiveJourney] = [:]
    private var orderedJourneyIDs: [UUID] = []

    init(
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        capacity: Int = 200
    ) {
        self.clock = clock
        self.capacity = max(1, capacity)
    }

    @discardableResult
    func beginBookOpen(documentKind: LatencyObservation.DocumentKind) -> UUID {
        begin(
            kind: .bookOpen,
            documentKind: documentKind,
            initialTransition: .openRequested
        )
    }

    /// Starts a short-lived playback journey. The caller records
    /// `audioQueued` when media is available and `audioAudible` only after
    /// the system player confirms it is actually rendering audio.
    @discardableResult
    func beginProgressivePlayback() -> UUID {
        begin(
            kind: .progressivePlayback,
            documentKind: .epub,
            initialTransition: .playRequested
        )
    }

    /// Starts a seek journey. A queued seek is intentionally not considered
    /// complete until the player reaches the requested target.
    @discardableResult
    func beginSeek() -> UUID {
        begin(
            kind: .seek,
            documentKind: .epub,
            initialTransition: .seekRequested
        )
    }

    private func begin(
        kind: LatencyObservation.JourneyKind,
        documentKind: LatencyObservation.DocumentKind,
        initialTransition: LatencyObservation.Transition
    ) -> UUID {
        let id = UUID()
        let journey = LatencyObservation.Journey(
            id: id,
            kind: kind,
            context: .init(documentKind: documentKind, cacheClass: .unknown),
            records: [.init(transition: initialTransition, elapsedNanoseconds: 0)]
        )
        lock.lock()
        activeJourneys[id] = ActiveJourney(
            startedAtNanoseconds: clock(),
            journey: journey
        )
        orderedJourneyIDs.append(id)
        trimToCapacityLocked()
        lock.unlock()
        return id
    }

    func classifyCache(_ cacheClass: LatencyObservation.CacheClass, for journeyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return }
        active.journey.context.cacheClass = cacheClass
        activeJourneys[journeyID] = active
    }

    func classifyDocument(_ documentKind: LatencyObservation.DocumentKind, for journeyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return }
        active.journey.context = .init(
            documentKind: documentKind,
            cacheClass: active.journey.context.cacheClass
        )
        activeJourneys[journeyID] = active
    }

    @discardableResult
    func record(_ transition: LatencyObservation.Transition, for journeyID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard transition != .cancelled,
              var active = activeJourneys[journeyID],
              !active.isTerminal
        else {
            return false
        }
        active.journey.records.append(
            .init(transition: transition, elapsedNanoseconds: elapsedNanoseconds(for: active))
        )
        activeJourneys[journeyID] = active
        return true
    }

    @discardableResult
    func cancel(_ journeyID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return false }
        active.journey.records.append(
            .init(transition: .cancelled, elapsedNanoseconds: elapsedNanoseconds(for: active))
        )
        active.isTerminal = true
        activeJourneys[journeyID] = active
        return true
    }

    func finish(_ journeyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return }
        active.isTerminal = true
        activeJourneys[journeyID] = active
    }

    func snapshot() -> [LatencyObservation.Journey] {
        lock.lock()
        defer { lock.unlock() }
        return orderedJourneyIDs.compactMap { activeJourneys[$0]?.journey }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot())
    }

    func writeDiagnosticExport() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("performance-diagnostics-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try exportData().write(to: url, options: .atomic)
        return url
    }

    private func elapsedNanoseconds(for active: ActiveJourney) -> UInt64 {
        let last = active.journey.records.last?.elapsedNanoseconds ?? 0
        let now = clock()
        let elapsed = now >= active.startedAtNanoseconds
            ? now - active.startedAtNanoseconds
            : 0
        return max(last, elapsed)
    }

    private func trimToCapacityLocked() {
        while orderedJourneyIDs.count > capacity {
            let removedID = orderedJourneyIDs.removeFirst()
            activeJourneys.removeValue(forKey: removedID)
        }
    }
}
