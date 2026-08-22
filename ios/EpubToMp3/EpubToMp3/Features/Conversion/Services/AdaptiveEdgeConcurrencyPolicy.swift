enum AdaptiveEdgeConcurrencyPolicy {
    enum Connectivity: Equatable {
        case unavailable
        case wifi
        case cellular
    }

    enum ThermalState: Equatable {
        case nominal
        case fair
        case serious
        case critical
    }

    enum Strategy: Equatable {
        case serial
        case hybrid(maxConcurrentBackfillChunks: Int)
    }

    static func resolve(
        automaticModeEnabled: Bool,
        maxPerformanceRequested: Bool,
        connectivity: Connectivity,
        isLowPowerModeEnabled: Bool,
        thermalState: ThermalState,
        recentEdgeFailures: Int
    ) -> Strategy {
        guard automaticModeEnabled || maxPerformanceRequested,
              connectivity == .wifi,
              !isLowPowerModeEnabled,
              thermalState != .serious,
              thermalState != .critical else {
            return .serial
        }

        let maxConcurrentBackfillChunks: Int
        switch recentEdgeFailures {
        case ...0:
            maxConcurrentBackfillChunks = 3
        case 1:
            maxConcurrentBackfillChunks = 2
        default:
            maxConcurrentBackfillChunks = 1
        }
        return .hybrid(maxConcurrentBackfillChunks: maxConcurrentBackfillChunks)
    }
}
