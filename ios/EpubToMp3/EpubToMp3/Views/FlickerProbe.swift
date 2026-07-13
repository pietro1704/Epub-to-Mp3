import Foundation
import Combine
import os.log

/// Test-only instrumentation that counts transient "flicker" events in the
/// paginated reader so a UI test can assert *zero* of them happened during a
/// page turn / chapter switch / chrome toggle — without trying to diff
/// screenshots frame-by-frame (which XCUITest cannot do reliably).
///
/// A "flicker event" is any of the visual glitches the user reported:
///
///  - `staleSlicePushed` — the page view controller re-pushed a DIFFERENT
///    attributed slice into the currently-displayed page controller while no
///    user gesture moved the index. On screen this is the text visibly
///    changing/snapping back for a frame.
///  - `spuriousRenavigation` — `updateUIViewController` fired a programmatic
///    `setViewControllers` that fought an in-flight or just-completed turn
///    (the classic "tap back, bounce forward" / flicker-to-page-0 race).
///  - `emptyPagesShown` — the paginated body fell back to `lastValidPages`
///    (stale chapter) or an empty array because the fresh pagination wasn't
///    ready, briefly flashing old content / the background.
///
/// The probe is a no-op unless armed via the `-uiTestFlickerProbe` launch
/// argument, so it carries zero cost in production and in normal runs.
/// Events are recorded on the main actor (all call sites are main-thread UI
/// code) so no locking is required.
enum FlickerEvent: String, CaseIterable {
    case staleSlicePushed
    case spuriousRenavigation
    case emptyPagesShown
}

@MainActor
final class FlickerProbe: ObservableObject {
    static let shared = FlickerProbe()

    /// Armed only when the host app is launched by a UI test with the
    /// `-uiTestFlickerProbe` argument. Production launches leave this false
    /// and every `record(_:)` call returns immediately.
    private(set) var isArmed: Bool =
        ProcessInfo.processInfo.arguments.contains("-uiTestFlickerProbe")

    @Published private(set) var counts: [FlickerEvent: Int] = [:]
    /// Live "chapterIndex/totalChapters" surfaced to UI tests so they can
    /// detect a real chapter swap deterministically (instead of inferring it
    /// from the page indicator resetting). Updated by InstantReaderView.
    @Published var chapterInfo: String = "?/?"

    private init() {
        if isArmed, let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("flicker-debug.log"))
        }
    }

    /// Force-arm for unit tests that exercise the probe directly without a
    /// launch argument.
    func arm() { isArmed = true }

    func record(_ event: FlickerEvent) {
        guard isArmed else { return }
        counts[event, default: 0] += 1
    }

    func count(_ event: FlickerEvent) -> Int { counts[event] ?? 0 }

    /// Diagnostic logging routed to the unified log under the
    /// `flicker` category. Only emits when armed, so production stays quiet.
    /// Inspect on device with: `log stream --predicate 'category == "flicker"'`.
    private let logger = Logger(subsystem: "com.pietrocode.epubtomp3", category: "flicker")
    /// Serial queue for the blocking parts of `log` (file write + stdout).
    /// `log` is called on every reader body eval / page-controller update — up
    /// to ~60 Hz during a burst. Doing the FileHandle open/seek/write/close and
    /// `print` synchronously on the main thread at that rate added enough
    /// per-frame latency to tip a borderline reader layout into a transient
    /// oscillation that does NOT occur in production (Stage-0 finding: the
    /// self-sustaining burst existed only when the probe was armed). Moving the
    /// I/O off-main removes that self-perturbation so the probe measures the
    /// real reader timing.
    private let ioQueue = DispatchQueue(
        label: "com.pietrocode.epubtomp3.flickerprobe.io", qos: .utility
    )
    /// Last log line, surfaced to UI tests via the overlay so device runs can
    /// read diagnostics without a console stream.
    @Published private(set) var lastLog: String = ""
    private var logHistory: [String] = []
    /// Throttle for the `@Published lastLog` update. Publishing on every call
    /// re-rendered the diagnostic overlay at ~60 Hz — another source of
    /// self-perturbation. UI tests only need an eventually-current value.
    private var lastLogPublishedAt: Date = .distantPast
    /// Append-only debug file, far more reliable than os_log/syslog relay
    /// under high message volume (observed on-device: the legacy syslog
    /// relay silently drops lines during a burst of rapid page-turn/init
    /// logging, including exactly the message needed to diagnose a race).
    /// Pull with: `xcrun devicectl device copy from-device --domain-type
    /// appDataContainer --domain-identifier <bundle-id> --source
    /// Documents/flicker-debug.log --destination <local path> --device <udid>`.
    private lazy var debugFileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("flicker-debug.log")
    }()
    /// `nonisolated static` so it can run off the main actor on `ioQueue`
    /// without capturing any `@MainActor` state — only the pre-rendered line
    /// and the file URL are passed in.
    nonisolated private static func appendToDebugFile(url: URL?, line: String) {
        guard let url, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    func log(_ message: String) {
        guard isArmed else { return }
        logger.debug("\(message, privacy: .public)")  // os_log is non-blocking
        // Timestamp captured HERE (call time), not at write time, so the
        // off-main write preserves accurate timing.
        let entry = "\(Date().timeIntervalSince1970) \(message)"
        let url = debugFileURL
        // File write + stdout are the only blocking ops — do them off-main,
        // serialized so line order is preserved. print() goes through the
        // process's own stdout, which the legacy `idevicesyslog` relay taps
        // (os_log(.debug) alone doesn't reach it under burst).
        ioQueue.async {
            Self.appendToDebugFile(url: url, line: entry)
            print("FLICKER: \(message)")
        }
        logHistory.append(message)
        if logHistory.count > 8 { logHistory.removeFirst(logHistory.count - 8) }
        // Throttle the overlay-driving publish to ~5 Hz.
        let now = Date()
        if now.timeIntervalSince(lastLogPublishedAt) >= 0.2 {
            lastLogPublishedAt = now
            lastLog = logHistory.joined(separator: " | ")
        }
    }

    /// Total across every event kind — the single number a UI test asserts
    /// is 0 after a scripted interaction.
    var total: Int { counts.values.reduce(0, +) }

    func reset() { counts.removeAll() }

    /// Test-only: block until any queued off-main log I/O has flushed, then
    /// return the debug file's contents. Lets a unit test assert that
    /// `log(_:)`'s asynchronous write actually lands on disk.
    func debugLogContentsForTests() -> String? {
        ioQueue.sync {}
        guard let url = debugFileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Convenience used by the UI test's hidden overlay so a snapshot of the
    /// accessibility tree always carries the live summary.
    nonisolated static let summaryAXId = "flicker.probe.summary"

    /// Compact, parseable summary surfaced to the UI test via a hidden
    /// accessibility element, e.g. `"stale=0 spurious=0 empty=0"`.
    var summary: String {
        FlickerEvent.allCases
            .map { "\($0.shortKey)=\(count($0))" }
            .joined(separator: " ")
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Hidden overlay that surfaces the live flicker summary to a UI test via
/// the accessibility tree. Rendered only when the probe is armed
/// (`-uiTestFlickerProbe`), so it never appears in production. The label
/// updates reactively (the probe is an `ObservableObject`), and a reset
/// button lets the test zero the counters before each scripted interaction.
struct FlickerProbeOverlay: View {
    @ObservedObject private var probe = FlickerProbe.shared

    var body: some View {
        if probe.isArmed {
            VStack(spacing: 0) {
                Text(probe.summary)
                    .accessibilityIdentifier(FlickerProbe.summaryAXId)
                    .accessibilityLabel(probe.summary)
                Text(probe.chapterInfo)
                    .accessibilityIdentifier("flicker.probe.chapter")
                    .accessibilityLabel(probe.chapterInfo)
                Text(probe.lastLog.isEmpty ? "—" : probe.lastLog)
                    .accessibilityIdentifier("flicker.probe.lastlog")
                    .accessibilityLabel(probe.lastLog)
                Button("flicker-reset") { probe.reset() }
                    .accessibilityIdentifier("flicker.probe.reset")
                    .buttonStyle(.plain)
            }
            // Keep the controls a real, hittable size in the top-leading
            // corner (not a 1x1 sub-pixel speck that XCUITest can miss), but
            // nearly transparent so it never disturbs the reading surface.
            .font(.system(size: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(0.02)
            .allowsHitTesting(true)
        }
    }
}
#endif

private extension FlickerEvent {
    var shortKey: String {
        switch self {
        case .staleSlicePushed:     return "stale"
        case .spuriousRenavigation: return "spurious"
        case .emptyPagesShown:      return "empty"
        }
    }
}
