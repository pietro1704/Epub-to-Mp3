import Foundation
import Dispatch

/// Optional inclusive synchronous scopes, never time to first rendered frame.
final class AppStartupTiming: @unchecked Sendable {
    enum Phase: String, Codable, Sendable {
        case libraryStoreCreation = "app.library_store_creation"
        case libraryDecodeApply = "library.decode_apply"
        case macDelegateCreation = "macos.delegate_creation"
        case macWindowSetup = "macos.window_setup"
        case runtimeActivation = "runtime.activation"
        case widgetReloadRequest = "runtime.widget_reload_request"
        case bookmarksPrune = "maintenance.bookmarks"
        case fulltextPrune = "maintenance.fulltext"
    }

    enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    struct Sample: Encodable, Sendable {
        let traceID: UUID
        let spanID: UInt64
        let phase: Phase
        let startedAtNanoseconds: UInt64
        let endedAtNanoseconds: UInt64
        let outcome: Outcome
        let durationKind = "inclusive_synchronous_scope"
        var durationMilliseconds: Double {
            Double(endedAtNanoseconds - startedAtNanoseconds) / 1_000_000
        }

        enum CodingKeys: String, CodingKey {
            case traceID, spanID, phase, startedAtNanoseconds, endedAtNanoseconds,
                 durationMilliseconds, durationKind, outcome
        }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(traceID, forKey: .traceID)
            try fields.encode(spanID, forKey: .spanID)
            try fields.encode(phase, forKey: .phase)
            try fields.encode(startedAtNanoseconds, forKey: .startedAtNanoseconds)
            try fields.encode(endedAtNanoseconds, forKey: .endedAtNanoseconds)
            try fields.encode(durationMilliseconds, forKey: .durationMilliseconds)
            try fields.encode(durationKind, forKey: .durationKind)
            try fields.encode(outcome, forKey: .outcome)
        }
    }

    static let shared = AppStartupTiming()
    let isEnabled: Bool
    private let traceID: UUID?
    private let clock: @Sendable () -> UInt64
    private let sink: @Sendable (Sample) -> Void
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sink: (@Sendable (Sample) -> Void)? = nil) {
        isEnabled = arguments.contains("-measureStartup")
        traceID = isEnabled ? UUID() : nil
        self.clock = clock
        self.sink = sink ?? { AppStartupTiming.log($0) }
    }

    func measure<Value>(_ phase: Phase, _ operation: () throws -> Value) rethrows -> Value {
        guard let traceID else { return try operation() }
        let spanID = lock.withLock { sequence += 1; return sequence }
        let started = clock()
        var outcome = Outcome.completed
        defer {
            let ended = clock()
            if ended >= started {
                sink(Sample(traceID: traceID, spanID: spanID, phase: phase,
                            startedAtNanoseconds: started, endedAtNanoseconds: ended, outcome: outcome))
            }
        }
        do { return try operation() }
        catch {
            outcome = error is CancellationError ? .cancelled : .failed
            throw error
        }
    }

    private static func log(_ sample: Sample) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(sample), let line = String(data: encoded, encoding: .utf8) else { return }
        NSLog("[StartupTiming] %@", line)
    }
}
