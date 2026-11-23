import Foundation
#if os(iOS)
import UIKit
import AVFoundation
#endif

/// Test-only breadcrumb log for the locked/background playback journey.
///
/// Off unless the app is launched with `-uiTestPlaybackTrace`. It records
/// timestamped lifecycle, audio-session, player-output, background-task and
/// segment-delivery events to `Library/Application Support/EpubToMp3/Diagnostics/
/// playback-trace.log` (copied from the container with `devicectl`, because the
/// unified log needs root). A gap in the periodic heartbeat is itself evidence
/// that the process was suspended. It never changes playback behavior.
final class PlaybackTrace: @unchecked Sendable {
    static let launchArgument = "-uiTestPlaybackTrace"
    static let shared = PlaybackTrace()

    private let queue = DispatchQueue(label: "epub2mp3.playback-trace", qos: .utility)
    private var handle: FileHandle?
    private(set) var isEnabled = false
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    #if os(iOS)
    private var tokens: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    #endif

    /// Starts the trace once when the launch argument is present.
    func startIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(Self.launchArgument), !isEnabled else { return }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        let directory = base.appendingPathComponent("EpubToMp3/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("playback-trace.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        isEnabled = handle != nil
        record("trace started pid=\(ProcessInfo.processInfo.processIdentifier)")
        #if os(iOS)
        DispatchQueue.main.async { self.installObservers() }
        #endif
    }

    /// Appends one line; a no-op unless the trace was requested.
    func record(_ event: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: Date())) \(event())\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            try? self?.handle?.write(contentsOf: data)
            try? self?.handle?.synchronize()
        }
    }

    #if os(iOS)
    /// Seconds iOS still grants a background task, or `nil` in the foreground.
    @MainActor static func backgroundTimeRemaining() -> String {
        let value = UIApplication.shared.backgroundTimeRemaining
        return value > 1_000_000 ? "unlimited" : String(format: "%.1f", value)
    }

    @MainActor private func installObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ describe: @escaping (Notification) -> String = { _ in "" }) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.record("\(name.rawValue) \(describe(note))")
            })
        }
        observe(UIApplication.willResignActiveNotification)
        observe(UIApplication.didEnterBackgroundNotification)
        observe(UIApplication.willEnterForegroundNotification)
        observe(UIApplication.didBecomeActiveNotification)
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification)
        observe(UIApplication.protectedDataDidBecomeAvailableNotification)
        observe(UIApplication.didReceiveMemoryWarningNotification)
        observe(ProcessInfo.thermalStateDidChangeNotification) { _ in "state=\(ProcessInfo.processInfo.thermalState.rawValue)" }
        observe(AVAudioSession.interruptionNotification) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.intValue ?? -1
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            return "type=\(type) reason=\(reason)"
        }
        observe(AVAudioSession.routeChangeNotification) { note in
            "reason=\((note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? -1)"
        }
        observe(AVAudioSession.mediaServicesWereResetNotification)
        heartbeat = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let session = AVAudioSession.sharedInstance()
                self?.record("heartbeat app=\(UIApplication.shared.applicationState.rawValue) "
                    + "bgRemaining=\(Self.backgroundTimeRemaining()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) "
                    + "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) otherAudio=\(session.isOtherAudioPlaying) "
                    + "route=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
            }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }
    #endif
}
