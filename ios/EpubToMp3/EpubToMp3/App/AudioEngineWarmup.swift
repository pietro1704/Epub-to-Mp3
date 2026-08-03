import Foundation
import Combine

@MainActor
final class AudioEngineWarmup: ObservableObject {
    enum State: Equatable { case idle, warming, ready, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String = ""
    private var task: Task<Bool, Never>?
    private let preflight: @MainActor () async throws -> Void

    init(preflight: @escaping @MainActor () async throws -> Void = {
        try await PythonBridge.shared.preflightRuntime()
    }) {
        self.preflight = preflight
    }

    var isVisible: Bool {
        if case .warming = state { return true }
        if case .failed = state { return true }
        return false
    }

    var stateLabel: String {
        switch state {
        case .idle: return L10n.string("audioWarmup.state.idle")
        case .warming: return L10n.string("audioWarmup.state.loading")
        case .ready: return L10n.string("audioWarmup.state.ready")
        case .failed: return L10n.string("audioWarmup.state.failed")
        }
    }

    var progressLabel: String { "\(Int((progress * 100).rounded()))%" }

    @discardableResult
    func start() async -> Bool {
        if case .ready = state { return true }
        if let task { return await task.value }
        state = .warming
        progress = 0
        message = L10n.string("audioWarmup.loading")
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            do {
                self.progress = 0.15
                try await self.preflight()
                guard !Task.isCancelled else {
                    self.state = .idle
                    self.progress = 0
                    self.task = nil
                    return false
                }
                self.progress = 1
                self.message = L10n.string("audioWarmup.ready")
                self.state = .ready
                self.task = nil
                return true
            } catch {
                self.progress = 0
                self.message = error.localizedDescription
                self.state = .failed(error.localizedDescription)
                self.task = nil
                return false
            }
        }
        self.task = task
        return await task.value
    }

    func waitUntilReady() async -> Bool { await start() }
}
