import Dispatch
import Foundation

enum LatencyObservation {
    struct StreamPublication: Codable, Equatable, Sendable {
        let publicationID: String
        let producer: ProducerObservation

        private enum CodingKeys: String, CodingKey {
            case publicationID = "publicationId"
            case producer
        }

        init?(publicationID: String, producer: ProducerObservation) {
            guard Self.isOpaquePublicationID(publicationID) else { return nil }
            self.publicationID = publicationID
            self.producer = producer
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let identifier = try values.decode(String.self, forKey: .publicationID)
            let producer = try values.decode(ProducerObservation.self, forKey: .producer)
            guard let publication = Self(publicationID: identifier, producer: producer) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid opaque publication identifier"))
            }
            self = publication
        }

        private static func isOpaquePublicationID(_ value: String) -> Bool {
            let count = value.utf8.count
            guard count > 0, count <= 36 else { return false }
            let bytes = Array(value.utf8)
            if count <= 20, bytes.allSatisfy({ (48...57).contains($0) }) { return true }
            if count == 32, bytes.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) { return true }
            return count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased()
        }
    }

    /// Producer-relative elapsed values must never enter client-clock records.
    struct ProducerObservation: Codable, Equatable, Sendable {
        let version: Int
        let attemptID: UUID
        let segmentReadyElapsedNanoseconds: UInt64
        let artifactPublishedElapsedNanoseconds: UInt64

        private enum CodingKeys: String, CodingKey {
            case version
            case attemptID = "attemptId"
            case segmentReadyElapsedNanoseconds
            case artifactPublishedElapsedNanoseconds
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            attemptID = try values.decode(UUID.self, forKey: .attemptID)
            segmentReadyElapsedNanoseconds = try values.decode(
                UInt64.self, forKey: .segmentReadyElapsedNanoseconds)
            artifactPublishedElapsedNanoseconds = try values.decode(
                UInt64.self, forKey: .artifactPublishedElapsedNanoseconds)
            guard version == 1,
                  artifactPublishedElapsedNanoseconds >= segmentReadyElapsedNanoseconds else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid producer observation version or ordering"))
            }
        }
    }

    enum JourneyKind: String, Codable, Equatable, Sendable {
        case bookOpen = "book_open"
        case progressivePlayback = "progressive_playback"
        case seek
    }

    enum Transition: String, Codable, Equatable, Sendable {
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

    enum DocumentKind: String, Codable, Equatable, Sendable {
        case epub
        case selectableTextPDF = "selectable_text_pdf"
        case normalizedScannedPDF = "normalized_scanned_pdf"
    }

    enum CacheClass: String, Codable, Equatable, Sendable {
        case unknown
        case inMemoryWarm = "in_memory_warm"
        case preparedDisk = "prepared_disk"
        case cold
    }

    struct Context: Codable, Equatable, Sendable {
        let documentKind: DocumentKind
        var cacheClass: CacheClass
    }

    struct Record: Codable, Equatable, Sendable {
        let transition: Transition
        let elapsedNanoseconds: UInt64
    }

    struct Journey: Codable, Equatable, Sendable {
        let id: UUID
        let kind: JourneyKind
        var context: Context
        var records: [Record]
        var streamPublication: StreamPublication? = nil
        var streamRequest: StreamRequestReceipt? = nil
    }
}

/// Holds privacy-safe timing observations locally until the listener
/// explicitly exports diagnostics. Book content and identity never enter this
/// boundary: records retain only a random journey identifier, document class,
/// cache class, transition, and monotonic elapsed time.
final class LatencyObservationStore: @unchecked Sendable {
    typealias Clock = () -> UInt64

    static let shared: LatencyObservationStore = {
        let environment = ProcessInfo.processInfo.environment
        let isTesting = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"]
            .contains { environment[$0] != nil }
        // Native integration tests use the shared collector, but their synthetic
        // journeys must never hydrate or overwrite the listener's diagnostics.
        return LatencyObservationStore(persistence: isTesting ? nil : .applicationStorage())
    }()

    private struct ActiveJourney {
        let startedAtNanoseconds: UInt64
        var journey: LatencyObservation.Journey
        var isTerminal = false
    }

    private let clock: Clock
    private let capacity: Int
    private let persistence: LatencyObservationPersistence?
    private var persistenceRevision: UInt64 = 0
    private var persistenceReady = false
    private let lock = NSLock()
    private var activeJourneys: [UUID: ActiveJourney] = [:]
    private var orderedJourneyIDs: [UUID] = []

    init(
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        capacity: Int = 200,
        persistence: LatencyObservationPersistence? = nil
    ) {
        self.clock = clock
        self.capacity = min(LatencyObservationPersistence.maximumJourneys, max(1, capacity))
        self.persistence = persistence
        persistenceReady = persistence == nil
        persistence?.load { [weak self] journeys in self?.restoreHistory(journeys) }
    }

    private func restoreHistory(_ journeys: [LatencyObservation.Journey]) {
        lock.lock()
        defer { lock.unlock() }
        let liveIDs = Set(orderedJourneyIDs)
        let history = journeys.filter { !liveIDs.contains($0.id) }
        for journey in history {
            // Historical elapsed values belong to a prior process clock.
            // Never resume or fabricate a cancellation for an archived journey.
            activeJourneys[journey.id] = ActiveJourney(
                startedAtNanoseconds: 0, journey: journey, isTerminal: true)
        }
        orderedJourneyIDs = history.map(\.id) + orderedJourneyIDs
        trimToCapacityLocked()
        persistenceReady = true
        // Do not write an empty archive merely because there was no valid file.
        if !orderedJourneyIDs.isEmpty { schedulePersistenceLocked() }
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
        schedulePersistenceLocked()
        lock.unlock()
        return id
    }

    func classifyCache(_ cacheClass: LatencyObservation.CacheClass, for journeyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return }
        active.journey.context.cacheClass = cacheClass
        activeJourneys[journeyID] = active
        schedulePersistenceLocked()
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
        schedulePersistenceLocked()
    }

    @discardableResult
    func record(_ transition: LatencyObservation.Transition, for journeyID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard transition != .cancelled,
              var active = activeJourneys[journeyID],
              !active.isTerminal,
              Self.isValid(transition, for: active.journey)
        else {
            return false
        }
        active.journey.records.append(
            .init(transition: transition, elapsedNanoseconds: elapsedNanoseconds(for: active))
        )
        activeJourneys[journeyID] = active
        schedulePersistenceLocked()
        return true
    }

    @discardableResult
    func attachStreamPublication(
        _ publication: LatencyObservation.StreamPublication, for journeyID: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal,
              active.journey.kind != .bookOpen,
              active.journey.streamPublication == nil,
              active.journey.streamRequest.map({ $0.publicationID == publication.publicationID }) ?? true
        else { return false }
        active.journey.streamPublication = publication
        activeJourneys[journeyID] = active
        schedulePersistenceLocked()
        return true
    }

    @discardableResult
    func attachStreamRequest(_ request: LatencyObservation.StreamRequestReceipt, for journeyID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard request.journeyID == journeyID,
              var active = activeJourneys[journeyID], !active.isTerminal,
              active.journey.kind != .bookOpen, active.journey.streamRequest == nil,
              active.journey.streamPublication.map({ $0.publicationID == request.publicationID }) ?? true
        else { return false }
        active.journey.streamRequest = request
        activeJourneys[journeyID] = active
        schedulePersistenceLocked()
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
        schedulePersistenceLocked()
        return true
    }

    func finish(_ journeyID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var active = activeJourneys[journeyID], !active.isTerminal else { return }
        active.isTerminal = true
        activeJourneys[journeyID] = active
        schedulePersistenceLocked()
    }

    func flushPersistence() async {
        await persistence?.flush()
    }

    private func schedulePersistenceLocked() {
        guard persistenceReady, let persistence else { return }
        persistenceRevision += 1
        persistence.schedule(orderedJourneyIDs.compactMap { activeJourneys[$0]?.journey },
                             revision: persistenceRevision)
    }

    func snapshot() -> [LatencyObservation.Journey] {
        lock.lock()
        defer { lock.unlock() }
        return orderedJourneyIDs.compactMap { activeJourneys[$0]?.journey }
    }

    /// Returns the latest client-monotonic elapsed time for correlation with
    /// the backend. The journey payload itself stays redacted and local.
    func latestElapsedNanoseconds(for journeyID: UUID) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return activeJourneys[journeyID]?.journey.records.last?.elapsedNanoseconds
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot())
    }

    func writeDiagnosticExport(to destination: URL? = nil) async throws -> URL {
        await flushPersistence()
        let url = destination ?? FileManager.default.temporaryDirectory
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

    /// Diagnostics record listener-visible boundaries, not implementation
    /// milestones. In particular, a prepared queue cannot become audible
    /// until the queue boundary was observed first.
    private static func isValid(
        _ transition: LatencyObservation.Transition,
        for journey: LatencyObservation.Journey
    ) -> Bool {
        let recorded = Set(journey.records.map(\.transition))
        switch journey.kind {
        case .bookOpen:
            switch transition {
            case .readableContent, .controlsUsable, .firstPDFPage:
                return !recorded.contains(transition)
            default:
                return false
            }
        case .progressivePlayback:
            switch transition {
            case .audioQueued:
                return !recorded.contains(.audioQueued) && !recorded.contains(.audioAudible)
            case .audioAudible:
                return recorded.contains(.audioQueued) && !recorded.contains(.audioAudible)
            default:
                return false
            }
        case .seek:
            return transition == .seekTargetReached && !recorded.contains(.seekTargetReached)
        }
    }

    private func trimToCapacityLocked() {
        while orderedJourneyIDs.count > capacity {
            let removedID = orderedJourneyIDs.removeFirst()
            activeJourneys.removeValue(forKey: removedID)
        }
    }
}
