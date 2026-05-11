import Foundation
import Observation

#if canImport(AppKit)
import AppKit
#endif

/// Lifecycle manager for the embedded Python sidecar (PyInstaller onefile
/// build of `python_app.desktop_main`). Mirrors what the Tauri shell did
/// in Rust: pick a free port, launch the binary with
/// `EPUB_TO_MP3_PORT=<port>`, poll `/api/health` until it answers, then
/// publish the URL so the rest of the SwiftUI app can hit it via
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
@Observable
final class SidecarManager {

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

    private(set) var state: State = .idle

    #if canImport(AppKit)
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var terminationObserver: NSObjectProtocol?
    #endif

    /// Fired (on main) when the sidecar process dies *after* having been
    /// healthy. Lets the host app clear `AppSettings.sidecarURL` so
    /// stale endpoints don't keep firing into a dead loopback port and
    /// optionally re-call `start()` to spawn a fresh one.
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

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        state = .starting
        do {
            try proc.run()
        } catch {
            state = .failed("Failed to launch sidecar: \(error.localizedDescription)")
            return state
        }

        self.process = proc
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
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
                self.state = .idle
                self.onSidecarDied?()
            }
        }

        // Wait for /api/health.
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let healthOk = await waitForHealth(baseURL: baseURL)
        if !healthOk {
            // Capture last bytes of stderr to surface why it died.
            let tail = readPipeTail(errPipe) ?? readPipeTail(outPipe) ?? ""
            stop()
            state = .failed("Sidecar did not become healthy within \(Int(healthcheckTimeout))s. \(tail)")
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
    func stop() {
        #if canImport(AppKit)
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it 2s to exit cleanly, then SIGKILL.
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        if let token = terminationObserver {
            NotificationCenter.default.removeObserver(token)
            terminationObserver = nil
        }
        if case .running = state { state = .idle }
        #endif
    }

    // MARK: - Helpers

    #if canImport(AppKit)
    private func installTerminationHandler() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
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

    private func waitForHealth(baseURL: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(healthcheckTimeout)
        let url = baseURL.appendingPathComponent("api/health")
        let session = URLSession(configuration: .ephemeral)
        while Date() < deadline {
            do {
                let (_, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // Process not listening yet — keep waiting.
            }
            try? await Task.sleep(nanoseconds: UInt64(healthcheckInterval * 1_000_000_000))
        }
        return false
    }

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
