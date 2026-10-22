import Foundation
#if os(iOS)
import UIKit
#endif

/// Notification token ownership is nonisolated so ARC cleanup is always safe.
final class ConversionResourceMonitor {
    private var resourceObservers: [NSObjectProtocol] = []
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void,
         onMemoryPressure: @escaping @MainActor @Sendable () -> Void) {
        resourceObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in onChange() }
            },
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in onChange() }
            }
        ]
        #if os(iOS)
        resourceObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in onMemoryPressure() }
            }
        )
        #elseif os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            Task { @MainActor in onMemoryPressure() }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    deinit {
        resourceObservers.forEach(NotificationCenter.default.removeObserver)
        #if os(macOS)
        memoryPressureSource?.cancel()
        #endif
    }
}
