import Foundation

/// Owns transient resource pressure; scheduler admission and work identity stay separate.
@MainActor
final class ConversionResourcePolicy {
    typealias ResourceConstraint = LocalAudioConversionScheduler.ResourceConstraint
    private(set) var constraint: ResourceConstraint = .stable
    /// Deterministic injection for tests and support diagnostics. Device
    /// notifications must not race this explicit boundary state back to
    /// nominal before the conversion loop has observed the yield.
    private var injectedResourceConstraint: ResourceConstraint?
    private var resourceContinuations: [CheckedContinuation<Void, Never>] = []
    private var memoryPressureRecoveryTask: Task<Void, Never>?
    private var memoryPressureActive = false

    private var monitor: ConversionResourceMonitor?

    init() {
        monitor = ConversionResourceMonitor(
            onChange: { [weak self] in self?.refreshDeviceResourceConstraint() },
            onMemoryPressure: { [weak self] in self?.reportMemoryPressure() }
        )
    }

    deinit { memoryPressureRecoveryTask?.cancel() }

    func setResourceConstraint(_ constraint: ResourceConstraint) {
        injectedResourceConstraint = constraint == .stable ? nil : constraint
        applyResourceConstraint(constraint)
    }

    private func applyResourceConstraint(_ constraint: ResourceConstraint) {
        if constraint != .memoryPressure {
            memoryPressureActive = false
        }
        self.constraint = constraint
        guard constraint == .stable else { return }
        let continuations = resourceContinuations
        resourceContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    /// Memory warnings are transient. Yield at the next chapter boundary, then
    /// resume after a short quiet window unless low-power or thermal pressure
    /// still applies. No audio write or pending navigation is cancelled.
    func reportMemoryPressure(recoveryDelay: TimeInterval = 5) {
        memoryPressureActive = true
        applyResourceConstraint(.memoryPressure)
        memoryPressureRecoveryTask?.cancel()
        memoryPressureRecoveryTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, recoveryDelay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.memoryPressureActive = false
            self?.refreshDeviceResourceConstraint()
        }
    }

    /// Samples resource state immediately before a new chapter starts. Memory
    /// pressure is reported separately through `setResourceConstraint`, while
    /// low-power and thermal state are available directly from Foundation.
    func refreshDeviceResourceConstraint() {
        guard injectedResourceConstraint == nil else { return }
        if memoryPressureActive { return }
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled {
            applyResourceConstraint(.lowPower)
            return
        }
        switch process.thermalState {
        case .serious, .critical:
            applyResourceConstraint(.thermalPressure)
        case .nominal, .fair:
            applyResourceConstraint(.stable)
        @unknown default:
            applyResourceConstraint(.stable)
        }
    }

    func waitForChange() async {
        guard constraint != .stable else { return }
        await withCheckedContinuation { continuation in
            resourceContinuations.append(continuation)
        }
    }
}
