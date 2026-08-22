import Foundation

#if canImport(Network)
import Network
#endif

/// Serializes local Edge conversions across books without cancelling work the
/// user already requested. A Wi-Fi-only request remains queued until Wi-Fi
/// returns, then continues in first-in-first-out order.
@MainActor
final class LocalAudioConversionScheduler {
    nonisolated static let didChangeNotification = Notification.Name("LocalAudioConversionScheduler.didChange")

    /// A codable description of work that may be resumed after iOS ends the
    /// process. The actual conversion closure is deliberately not persisted.
    struct ResumeRequest: Codable, Equatable, Sendable {
        var bookID: String
        var coalescingKey: String
        var requiresWiFi: Bool
        var priorityChapterIndices: [Int]
        var requestedChapterIndices: [Int]?
        var engine: String
        var voice: String
        var language: String?
        var clearCache: Bool
        var forceReprocess: Bool
        var maxPerformance: Bool
    }

    enum Connectivity: Equatable {
        case unavailable
        case wifi
        case cellular

        var isAllowedForWiFiOnlyWork: Bool {
            self == .wifi
        }
    }

    enum WorkState: Equatable {
        case queued
        case waitingForWiFi
        case generating
        case finished
        case failed(String)
    }

    typealias Operation = @MainActor () async throws -> JobSnapshot
    private typealias Continuation = CheckedContinuation<JobSnapshot, Error>

    private struct Work {
        let id: UUID
        let bookID: String
        let coalescingKey: String
        var requiresWiFi: Bool
        var resumeRequest: ResumeRequest?
        let operation: Operation
        var continuations: [Continuation]
    }

    private struct PersistedQueue: Codable {
        let schemaVersion: Int
        let requests: [ResumeRequest]
    }

    static let shared = LocalAudioConversionScheduler(persistence: .standard)

    private static let persistenceKey = "localAudioConversionScheduler.queue.v1"
    private static let persistenceSchemaVersion = 1

    private var connectivity: Connectivity
    private var queued: [Work] = []
    private var active: Work?
    private var states: [String: WorkState] = [:]
    private var chapterPriorities: [String: [Int]] = [:]
    private var pendingResumption: [ResumeRequest]
    private let persistence: UserDefaults?

    #if canImport(Network)
    private let pathMonitor: NWPathMonitor?
    #endif

    init(
        initialConnectivity: Connectivity = .unavailable,
        observesNetwork: Bool = true,
        persistence: UserDefaults? = nil
    ) {
        connectivity = initialConnectivity
        self.persistence = persistence
        pendingResumption = Self.loadPersistedRequests(from: persistence)
        for request in pendingResumption {
            chapterPriorities[request.bookID] = request.priorityChapterIndices
            let isAllowed = request.requiresWiFi
                ? initialConnectivity.isAllowedForWiFiOnlyWork
                : initialConnectivity != .unavailable
            states[request.bookID] = isAllowed
                ? .queued
                : .waitingForWiFi
        }
        #if canImport(Network)
        if observesNetwork {
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let connectivity = Self.connectivity(for: path)
                Task { @MainActor [weak self] in
                    self?.setConnectivity(connectivity)
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.pietrocode.epubtomp3.local-audio-network"))
        } else {
            pathMonitor = nil
        }
        #endif
    }

    deinit {
        #if canImport(Network)
        pathMonitor?.cancel()
        #endif
    }

    func submit(
        bookID: String,
        requiresWiFi: Bool,
        priorityChapterIndices: [Int] = [],
        coalescingKey: String,
        resumeRequest: ResumeRequest? = nil,
        operation: @escaping Operation
    ) async throws -> JobSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            // All embedded Edge requests share the user-selected network
            // policy. Reapply it here so a request created by an older
            // screen cannot keep a stale Wi-Fi-only requirement.
            setAllowsCellularConversion(!requiresWiFi)
            enqueueChapterPriorities(priorityChapterIndices, for: bookID)
            if var active, active.bookID == bookID, active.coalescingKey == coalescingKey {
                active.continuations.append(continuation)
                self.active = active
                persistQueue()
                return
            }
            if let existingIndex = queued.firstIndex(where: {
                $0.bookID == bookID && $0.coalescingKey == coalescingKey
            }) {
                queued[existingIndex].continuations.append(continuation)
                persistQueue()
                return
            }

            queued.append(Work(
                id: UUID(),
                bookID: bookID,
                coalescingKey: coalescingKey,
                requiresWiFi: requiresWiFi,
                resumeRequest: resumeRequest,
                operation: operation,
                continuations: [continuation]
            ))
            removePendingResumption(bookID: bookID, coalescingKey: coalescingKey)
            if active?.bookID != bookID {
                updateState(
                    isAllowed(requiresWiFi: requiresWiFi) ? .queued : .waitingForWiFi,
                    for: bookID
                )
            }
            persistQueue()
            startNextWorkIfPossible()
        }
    }

    /// A later TOC tap never cancels the current book. Instead the selected
    /// chapter becomes the next eligible conversion boundary for that book.
    func prioritize(bookID: String, chapterIndices: [Int]) {
        enqueueChapterPriorities(chapterIndices, for: bookID)
        updateResumePriority(bookID: bookID)
        persistQueue()
    }

    /// Returns and consumes work descriptions that survived a process exit.
    /// The coordinator immediately re-submits them with fresh closures.
    func takePendingResumeRequests() -> [ResumeRequest] {
        let requests = pendingResumption
        pendingResumption.removeAll()
        persistQueue()
        return requests
    }

    func pendingResumeRequests() -> [ResumeRequest] {
        pendingResumption
    }

    /// A clear/regenerate request is a one-time setup action. Once the
    /// conversion has prepared its durable store, a later process restart
    /// must preserve chapters that already completed.
    func markInitialCacheActionHandled(bookID: String) {
        guard var active, active.bookID == bookID else { return }
        active.resumeRequest?.clearCache = false
        active.resumeRequest?.forceReprocess = false
        self.active = active
        persistQueue()
    }

    func nextChapterIndex(
        bookID: String,
        available: Set<Int>,
        defaultOrder: [Int]
    ) -> Int? {
        var priorities = chapterPriorities[bookID] ?? []
        while let next = priorities.first {
            priorities.removeFirst()
            if available.contains(next) {
                chapterPriorities[bookID] = priorities
                return next
            }
        }
        chapterPriorities[bookID] = priorities
        return defaultOrder.first { available.contains($0) }
    }

    func setConnectivity(_ connectivity: Connectivity) {
        self.connectivity = connectivity
        refreshNetworkStates()
        resumeNetworkWaitersIfAllowed()
        startNextWorkIfPossible()
    }

    var currentConnectivity: Connectivity { connectivity }

    /// Applies the Settings cellular policy to work that is already queued or
    /// waiting. An active chapter is never cancelled; the conversion loop
    /// checks this policy at its next chapter boundary.
    func setAllowsCellularConversion(_ allowsCellularConversion: Bool) {
        let requiresWiFi = !allowsCellularConversion
        if var active {
            active.requiresWiFi = requiresWiFi
            active.resumeRequest?.requiresWiFi = requiresWiFi
            self.active = active
        }
        for index in queued.indices {
            var work = queued[index]
            work.requiresWiFi = requiresWiFi
            work.resumeRequest?.requiresWiFi = requiresWiFi
            queued[index] = work
        }
        for index in pendingResumption.indices {
            pendingResumption[index].requiresWiFi = requiresWiFi
        }
        refreshNetworkStates()
        resumeNetworkWaitersIfAllowed()
        persistQueue()
        startNextWorkIfPossible()
    }

    func state(for bookID: String) -> WorkState? {
        states[bookID]
    }

    /// Called by the conversion loop at a chapter boundary. It never cancels
    /// a conversion; it waits for a permitted connection and resumes the same
    /// book once the scheduler has Wi-Fi again.
    func waitForNetworkPermission(bookID: String) async {
        while true {
            guard let active, active.bookID == bookID else { return }
            guard !isAllowed(requiresWiFi: active.requiresWiFi) else {
                updateState(.generating, for: bookID)
                return
            }
            updateState(.waitingForWiFi, for: bookID)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                permissionContinuations.append(continuation)
            }
        }
    }

    private var permissionContinuations: [CheckedContinuation<Void, Never>] = []

    private func startNextWorkIfPossible() {
        guard active == nil, let next = queued.first else { return }
        guard isAllowed(requiresWiFi: next.requiresWiFi) else {
            updateState(.waitingForWiFi, for: next.bookID)
            return
        }
        queued.removeFirst()
        active = next
        updateState(.generating, for: next.bookID)
        persistQueue()

        Task { @MainActor [weak self] in
            do {
                let snapshot = try await next.operation()
                self?.finish(workID: next.id, result: .success(snapshot))
            } catch {
                self?.finish(workID: next.id, result: .failure(error))
            }
        }
    }

    private func finish(workID: UUID, result: Result<JobSnapshot, Error>) {
        guard let active, active.id == workID else { return }
        self.active = nil
        // A later request for the same book may already be queued while the
        // current chapter finishes. Keep its priority until that work gets a
        // chapter boundary; otherwise an explicit TOC/listen request loses
        // its requested chapter between two FIFO jobs.
        if !queued.contains(where: { $0.bookID == active.bookID }) {
            chapterPriorities.removeValue(forKey: active.bookID)
        }
        switch result {
        case .success(let snapshot):
            updateState(.finished, for: active.bookID)
            active.continuations.forEach { $0.resume(returning: snapshot) }
        case .failure(let error):
            updateState(.failed(error.localizedDescription), for: active.bookID)
            active.continuations.forEach { $0.resume(throwing: error) }
        }
        persistQueue()
        startNextWorkIfPossible()
    }

    private func isAllowed(requiresWiFi: Bool) -> Bool {
        requiresWiFi ? connectivity.isAllowedForWiFiOnlyWork : connectivity != .unavailable
    }

    private func refreshNetworkStates() {
        if let active {
            updateState(
                isAllowed(requiresWiFi: active.requiresWiFi) ? .generating : .waitingForWiFi,
                for: active.bookID
            )
        }
        for work in queued {
            updateState(
                isAllowed(requiresWiFi: work.requiresWiFi) ? .queued : .waitingForWiFi,
                for: work.bookID
            )
        }
    }

    private func resumeNetworkWaitersIfAllowed() {
        guard let active, isAllowed(requiresWiFi: active.requiresWiFi) else { return }
        let continuations = permissionContinuations
        permissionContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func enqueueChapterPriorities(_ chapterIndices: [Int], for bookID: String) {
        guard !chapterIndices.isEmpty else { return }
        var queue = chapterPriorities[bookID] ?? []
        for chapterIndex in chapterIndices where chapterIndex >= 0 && !queue.contains(chapterIndex) {
            queue.append(chapterIndex)
        }
        chapterPriorities[bookID] = queue
    }

    private func updateResumePriority(bookID: String) {
        let priority = chapterPriorities[bookID] ?? []
        if var active, active.bookID == bookID {
            active.resumeRequest?.priorityChapterIndices = priority
            self.active = active
        }
        for index in queued.indices where queued[index].bookID == bookID {
            var work = queued[index]
            work.resumeRequest?.priorityChapterIndices = priority
            queued[index] = work
        }
        for index in pendingResumption.indices where pendingResumption[index].bookID == bookID {
            pendingResumption[index].priorityChapterIndices = priority
        }
    }

    private func removePendingResumption(bookID: String, coalescingKey: String) {
        pendingResumption.removeAll {
            $0.bookID == bookID && $0.coalescingKey == coalescingKey
        }
    }

    private func persistQueue() {
        guard let persistence else { return }
        let requests = [active?.resumeRequest].compactMap { $0 }
            + queued.compactMap(\.resumeRequest)
            + pendingResumption
        guard requests.isEmpty == false else {
            persistence.removeObject(forKey: Self.persistenceKey)
            return
        }
        let payload = PersistedQueue(
            schemaVersion: Self.persistenceSchemaVersion,
            requests: requests
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        persistence.set(data, forKey: Self.persistenceKey)
    }

    private static func loadPersistedRequests(from persistence: UserDefaults?) -> [ResumeRequest] {
        guard let persistence,
              let data = persistence.data(forKey: persistenceKey),
              let payload = try? JSONDecoder().decode(PersistedQueue.self, from: data),
              payload.schemaVersion == persistenceSchemaVersion else {
            return []
        }
        return payload.requests
    }

    private func updateState(_ state: WorkState, for bookID: String) {
        states[bookID] = state
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["bookID": bookID]
        )
    }

    #if canImport(Network)
    nonisolated private static func connectivity(for path: NWPath) -> Connectivity {
        guard path.status == .satisfied else { return .unavailable }
        #if targetEnvironment(simulator)
        return .wifi
        #else
        return path.usesInterfaceType(.cellular) ? .cellular : .wifi
        #endif
    }
    #endif
}
