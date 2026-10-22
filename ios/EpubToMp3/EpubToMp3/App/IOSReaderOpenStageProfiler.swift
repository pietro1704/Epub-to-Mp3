#if os(iOS)
import UIKit

/// Temporary, opt-in stage capture for real-app relaunch profiling. It keeps
/// only stage names and monotonic timestamps, then emits one line at readiness.
final class IOSReaderOpenStageProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [(String, UInt64)] = []
    private var isRecording = false

    func begin(_ name: String, at timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if !isRecording {
            stages.removeAll(keepingCapacity: true)
            isRecording = true
        }
        stages.append((name, timestamp))
    }

    func record(_ name: String, at timestamp: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if name == "reader_open_requested", !isRecording {
            stages.removeAll(keepingCapacity: true)
            isRecording = true
        }
        guard isRecording else { return nil }
        stages.append((name, timestamp))
        guard name == "controls_usable" else { return nil }
        isRecording = false
        let origin = stages.first?.1 ?? timestamp
        return stages.map { name, time in
            "\(name)=\(Double(time - origin) / 1_000_000)ms"
        }.joined(separator: ",")
    }

    func observer() -> @Sendable (String, UInt64) -> Void {
        { [weak self] name, timestamp in
            guard let self, let summary = self.record(name, at: timestamp) else { return }
            NSLog("[APP21-reader-stages] %@", summary)
        }
    }
    func recordStartupStage(_ name: String) {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        if name == "root_view_did_load_started" {
            begin(name, at: timestamp)
        } else if let summary = record(name, at: timestamp) {
            NSLog("[APP21-reader-stages] %@", summary)
        }
    }


}

#endif
