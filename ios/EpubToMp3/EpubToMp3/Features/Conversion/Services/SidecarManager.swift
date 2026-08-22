import Foundation
import Combine

#if canImport(AppKit)
import AppKit

/// One bounded readiness wait shared by macOS reader and playback entry
/// points. The sidecar is intentionally asynchronous at launch; treating a
/// missing URL during that window as a conversion failure creates a race the
/// user cannot recover from without retrying the same action.
@MainActor
enum SidecarEndpoint {
    static func waitForReadyURL(
        settings: AppSettings,
        attempts: Int = 180,
        intervalNanoseconds: UInt64 = 500_000_000
    ) async -> URL? {
        for _ in 0..<attempts {
            if let url = settings.resolvedBaseURL {
                return url
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return nil
    }
}
#endif

/// Lifecycle manager for the embedded Python sidecar (PyInstaller onefile
/// build of `python_app.desktop_main`). Mirrors what the Tauri shell did
/// in Rust: pick a free port, launch the binary with
/// `EPUB_TO_MP3_PORT=<port>`, poll `/api/health` until it answers, then
/// publish the URL so the rest of the native app can hit it via
/// `APIClient`.
///
/// Lifetime is tied to the running NSApplication on macOS: the manager
/// installs an `NSApplication.willTerminateNotification` observer to
/// SIGTERM the child before the GUI process exits, so we don't leak
/// orphaned uvicorn workers. iOS / iPadOS builds skip the sidecar
/// entirely — the user keeps the manual `backendURL` from Settings,
/// matching slice-2 behaviour where the iOS app talks to `mise run web`
/// or an HF Spaces URL over the network.
///
/// The bundled binary is named `epub-to-mp3-server` and lives under
/// `Contents/Resources/` (macOS app) / `Frameworks/` is not used because
/// the binary is fully self-contained (PyInstaller onefile). Resources
/// is an executable-permitted location for app sandboxes; we copy it
/// with `chmod +x` preserved by the Xcode build phase.
final class SidecarManager: ObservableObject, @unchecked Sendable {

    enum State: Equatable {
        case idle
        case starting
        case running(URL)
        case failed(String)
        case unsupported   // iOS / iPadOS / unknown

        var statusLabel: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .running(let url): return "running @ \(url.absoluteString)"
            case .failed(let err): return "failed: \(err)"
            case .unsupported: return "unsupported"
            }
        }
    }

    @Published private(set) var state: State = .idle

    #if canImport(AppKit)
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var terminationObserver: NSObjectProtocol?
    /// Monotonic counter incremented on every `start()` call. After
    /// `waitForHealth` returns, the caller checks whether the generation
    /// still matches — if a newer `start()` has taken over (because the
    /// process died and `onSidecarDied` spawned a replacement), the stale
    /// caller bails instead of killing the newer process via `stop()`.
    private var startGeneration: UInt = 0
    /// Suppresses the `onSidecarDied` callback for terminations that
    /// were initiated by us (`stop()` during a failed health probe,
    /// app shutdown). Without this, a sidecar that times out its
    /// 90 s health check fires `onSidecarDied` → the host's restart
    /// path calls `start()` again → which spawns another sidecar →
    /// which also times out, ad infinitum. The user-visible symptom
    /// is hundreds of "Connection refused" lines and a fully-spinning
    /// CPU. We only want the death callback for SPONTANEOUS deaths
    /// (segfault, OOM, SIGPIPE), not deliberate teardowns.
    private var suppressDeathCallback = false
    /// Wall-clock instants of the last few sidecar deaths. Restart is
    /// rate-limited to 3 spontaneous deaths in any 60-second window —
    /// past that the manager goes `.failed` and *stops* respawning so
    /// the user can fix the underlying issue (missing python_app,
    /// disk full, conflicting port, etc.) instead of watching the
    /// CPU pin.
    private var recentDeaths: [Date] = []
    private let restartWindow: TimeInterval = 60
    private let maxRestartsPerWindow = 3
    #endif

    /// Fired (on main) when the sidecar process dies *spontaneously*
    /// after having been healthy. Lets the host app clear
    /// `AppSettings.sidecarURL` so stale endpoints don't keep firing
    /// into a dead loopback port and optionally re-call `start()` to
    /// spawn a fresh one. NOT fired for `stop()`-initiated or
    /// healthcheck-timeout terminations.
    var onSidecarDied: (@MainActor () -> Void)?

    private let healthcheckTimeout: TimeInterval = 90
    private let healthcheckInterval: TimeInterval = 0.4

    /// Start the sidecar and resolve when `/api/health` answers OK, or
    /// return the failure reason otherwise. Idempotent — if the process
    /// is already running we just hand back the live URL.
    @MainActor
    @discardableResult
    func start() async -> State {
        #if canImport(AppKit)
        if case .running = state { return state }
        if case .starting = state { return state }
        guard let binary = Self.locateBundledBinary() else {
            state = .failed("Sidecar binary not found in app bundle (Resources/epub-to-mp3-server). Tauri PyInstaller artefact must be copied at build time.")
            return state
        }

        let port: UInt16
        do {
            port = try Self.pickFreePort()
        } catch {
            state = .failed("Could not find a free local port: \(error.localizedDescription)")
            return state
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = []
        var env = ProcessInfo.processInfo.environment
        env["EPUB_TO_MP3_PORT"] = String(port)
        // Defensive — make sure the sidecar only talks to its loopback
        // socket and doesn't pick up env vars that would push it into
        // HF profile mode.
        env.removeValue(forKey: "SPACE_ID")
        proc.environment = env

        // The macOS host has no console to consume the sidecar's diagnostic
        // output. Leaving either stream attached to an unread pipe can make
        // Python logging fail with EPIPE during parsing or block once its
        // buffer fills, which aborts a conversion before its first chapter.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        state = .starting
        do {
            try proc.run()
        } catch {
            state = .failed("Failed to launch sidecar: \(error.localizedDescription)")
            return state
        }

        self.process = proc
        self.stdoutPipe = nil
        self.stderrPipe = nil
        installTerminationHandler()

        // Watch for the child dying. PyInstaller onefile binaries on
        // macOS sometimes exit unexpectedly (signal/memory issues),
        // and without this callback the rest of the app keeps polling
        // a dead loopback port forever — the user-visible symptom is
        // an unending stream of "Connection refused" log spam to
        // 127.0.0.1:NNNN. Push the .idle state back and notify
        // listeners so they can clear cached URLs / re-spawn.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                let suppressed = self.suppressDeathCallback
                self.suppressDeathCallback = false
                if suppressed {
                    // Deliberate teardown — leave state alone (the
                    // caller already set it to .idle or .failed).
                    return
                }
                self.state = .idle
                // Rate-limit auto-restart so a chronically-failing
                // sidecar can't pin the CPU. After N deaths in a
                // sliding window, give up and let the user see the
                // `.failed` state.
                let now = Date()
                self.recentDeaths.append(now)
                self.recentDeaths.removeAll { now.timeIntervalSince($0) > self.restartWindow }
                if self.recentDeaths.count > self.maxRestartsPerWindow {
                    self.state = .failed("Sidecar died \(self.recentDeaths.count) times in \(Int(self.restartWindow)) s. Stopping auto-restart; check logs.")
                    return
                }
                self.onSidecarDied?()
            }
        }

        // Wait for /api/health.
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        startGeneration += 1
        let myGeneration = startGeneration

        // PyInstaller onefiles that fail to unpack or hit a missing
        // dependency exit within ~100 ms. Catching DOA processes here
        // avoids even a single wasted health-check HTTP request (which
        // otherwise logs a "Connection refused" line per attempt).
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard myGeneration == startGeneration else { return state }
        if !proc.isRunning {
            suppressDeathCallback = true
            process = nil
            state = .failed("Sidecar exited immediately after launch.")
            return state
        }

        let healthOk = await waitForHealth(baseURL: baseURL, proc: proc)

        // A newer start() has taken over (process died → onSidecarDied
        // → restart). Don't touch state or kill the newer process.
        guard myGeneration == startGeneration else { return state }

        if !healthOk {
            suppressDeathCallback = true
            await stop()
            state = .failed("Sidecar did not become healthy within \(Int(healthcheckTimeout))s.")
            return state
        }

        state = .running(baseURL)
        return state
        #else
        state = .unsupported
        return state
        #endif
    }

    /// Terminate the child process if any. Safe to call multiple times.
    /// User-initiated teardown — sets `suppressDeathCallback = true`
    /// so the spontaneous-death restart path doesn't fire.
    ///
    /// Async variant uses cooperative `Task.sleep` polling, so calling
    /// this from a native lifecycle hook (or any main-actor context)
    /// no longer blocks the UI while we wait for the child to die.
    @MainActor
    func stop() async {
        #if canImport(AppKit)
        suppressDeathCallback = true
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it ~2s to exit cleanly, polling cooperatively, then
            // SIGKILL. 40 × 50 ms = 2 s, matching the previous busy-wait
            // budget without ever blocking the main thread.
            for _ in 0..<40 {
                if !proc.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        finishStopTeardown()
        #endif
    }

    /// Synchronous teardown for `NSApplication.willTerminateNotification`
    /// — the notification fires on the main thread and we have no
    /// async context there. We MUST NOT busy-wait on the main thread or
    /// the GUI freezes during app quit. Instead, hop the wait onto a
    /// dedicated dispatch queue and block the main thread on a
    /// semaphore, but only for the same 2 s budget. AppKit already
    /// gives terminationHandler enough time before reaping us, so this
    /// is bounded.
    func stopSynchronously() {
        #if canImport(AppKit)
        // `willTerminate` fires on the main thread (the MainActor's
        // executor), so this is effectively MainActor-isolated. Make
        // that contract explicit so we can mutate actor-isolated state.
        MainActor.assumeIsolated {
            suppressDeathCallback = true
            if let proc = process, proc.isRunning {
                proc.terminate()
                if proc.isRunning {
                    let sem = DispatchSemaphore(value: 0)
                    // Off-main queue so the main thread blocks on the
                    // semaphore, not on the polling loop itself.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let deadline = Date().addingTimeInterval(2)
                        while proc.isRunning && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        sem.signal()
                    }
                    _ = sem.wait(timeout: .now() + 2.5)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
            finishStopTeardown()
        }
        #endif
    }

    #if canImport(AppKit)
    /// Shared cleanup tail for `stop()` and `stopSynchronously()`.
    /// Drops pipe references, removes the willTerminate observer, and
    /// snaps state back to `.idle` if we were previously running.
    @MainActor
    private func finishStopTeardown() {
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        if let token = terminationObserver {
            NotificationCenter.default.removeObserver(token)
            terminationObserver = nil
        }
        if case .running = state { state = .idle }
    }
    #endif

    // MARK: - Helpers

    #if canImport(AppKit)
    private func installTerminationHandler() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willTerminate runs on the main thread and we have no
            // async context here. The sync variant hops the polling
            // loop onto a background queue so we don't freeze the UI.
            self?.stopSynchronously()
        }
    }

    /// Look for the sidecar binary in the app's `Resources/` directory.
    /// PyInstaller onefile binaries are self-contained, so a single
    /// `Bundle.main.url(forResource:withExtension:)` lookup is enough.
    static func locateBundledBinary() -> URL? {
        // Try a few candidate names so the build can drop in either the
        // unsuffixed name (preferred when the app is single-arch) or the
        // Tauri-style triple-suffixed name (compat with the existing
        // PyInstaller output).
        let candidates = [
            "epub-to-mp3-server",
            "epub-to-mp3-server-aarch64-apple-darwin",
            "epub-to-mp3-server-x86_64-apple-darwin",
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Bind a TCP socket to port 0 to ask the kernel for a free port,
    /// then close it and hand the number to the sidecar. There's a
    /// race window where another process could grab the same port
    /// between close and exec, but in practice 47860+offset is fine
    /// for a single-user desktop app.
    static func pickFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "SidecarManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: "SidecarManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard getResult == 0 else {
            throw NSError(domain: "SidecarManager", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "getsockname() failed"])
        }
        return UInt16(bigEndian: bound.sin_port)
    }
    #endif

    #if canImport(AppKit)
    private func waitForHealth(baseURL: URL, proc: Process) async -> Bool {
        let deadline = Date().addingTimeInterval(healthcheckTimeout)
        let url = baseURL.appendingPathComponent("api/health")
        let session = URLSession(configuration: .ephemeral)
        var interval = healthcheckInterval
        while Date() < deadline {
            if Task.isCancelled { return false }
            if !proc.isRunning { return false }
            do {
                let (_, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // Process not listening yet — back off.
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            interval = min(interval * 1.5, 5)
        }
        return false
    }
    #endif

    #if canImport(AppKit)
    private func readPipeTail(_ pipe: Pipe?) -> String? {
        guard let pipe else { return nil }
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return nil }
        let str = String(data: data, encoding: .utf8) ?? ""
        return str.suffix(1024).description
    }
    #endif
}
