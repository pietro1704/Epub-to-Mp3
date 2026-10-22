import Foundation
#if canImport(Network)
import Network
#endif

extension LocalAudioConversionScheduler {
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
        case waitingForResources
        case generating
        case finished
        case failed(String)
    }

    /// Conversion yields only at a chapter boundary. Playback and reader work
    /// are never cancelled, and the persisted request retains its priority.
    enum ResourceConstraint: Equatable {
        case stable
        case lowPower
        case memoryPressure
        case thermalPressure
    }

    struct PendingNavigation {
        let requestID: UUID
        let chapterIndex: Int
    }
}

extension LocalAudioConversionScheduler.Connectivity {
    #if canImport(Network)
    nonisolated static func from(path: NWPath) -> Self {
        guard path.status == .satisfied else { return .unavailable }
        #if targetEnvironment(simulator)
        return .wifi
        #else
        return path.usesInterfaceType(.cellular) ? .cellular : .wifi
        #endif
    }
    #endif
}
