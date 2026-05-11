// PythonEmbed.swift
//
// Spike (branch feat/ios-python-embed): proves that Edge-TTS can run
// in-process inside the SwiftUI iOS app, replacing the PyInstaller
// sidecar (which uses Process() — forbidden on iOS).
//
// macOS still uses the sidecar path (SidecarManager.swift). This file
// only compiles on iOS / simulator.
//
// Bootstrap requirements (run once before building):
//   ios/EpubToMp3/scripts/bootstrap-ios-python.sh
//
// See ios/PYTHON-EMBED.md for the full architecture write-up.

#if os(iOS) || targetEnvironment(simulator)

import Foundation
import PythonKit

enum PythonEmbedError: Error, LocalizedError {
    case stdlibMissing
    case sitePackagesMissing
    case pythonInitFailed(String)
    case edgeSynthFailed(String)
    case outputFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .stdlibMissing: return "python-stdlib not found in app bundle"
        case .sitePackagesMissing: return "site-packages not found in app bundle"
        case .pythonInitFailed(let m): return "Py_Initialize failed: \(m)"
        case .edgeSynthFailed(let m): return "Edge-TTS failed: \(m)"
        case .outputFileMissing(let p): return "MP3 not written at \(p)"
        }
    }
}

/// Thin wrapper around an in-process CPython interpreter loaded from
/// Python.xcframework. Use `PythonEmbed.shared.convertWithEdgeTTS(...)`
/// to synthesize a chunk; the wrapper handles one-time bootstrap on
/// first call.
final class PythonEmbed: @unchecked Sendable {
    static let shared = PythonEmbed()

    private let lock = NSLock()
    private var initialized = false
    /// Strong reference to the PythonKit closure object we install as
    /// the Edge-TTS transport. PythonKit wraps Swift closures in
    /// `PythonFunction`; if Swift drops its reference the Python side
    /// gets a dangling callback and segfaults the first time it fires.
    /// Holding the closure here for the interpreter's lifetime is
    /// cheap (one slot) and keeps the bridge alive.
    private var edgeTransport: PythonObject?

    private init() {}

    // MARK: - Bootstrap

    /// Idempotent. Initializes CPython with PYTHONHOME / PYTHONPATH
    /// pointing at the bundled stdlib + site-packages.
    func bootstrap() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }

        let bundle = Bundle.main

        guard let stdlib = bundle.path(forResource: "python-stdlib", ofType: nil) else {
            throw PythonEmbedError.stdlibMissing
        }
        guard let sitePackages = bundle.path(forResource: "site-packages", ofType: nil) else {
            throw PythonEmbedError.sitePackagesMissing
        }

        // PYTHONHOME must point at a directory containing `lib/python3.X`
        // OR be set alongside PYTHONPATH that explicitly lists the stdlib.
        // Beeware ships python-stdlib as the stdlib root, so we set
        // PYTHONPATH = stdlib:site-packages and PYTHONHOME = stdlib.
        setenv("PYTHONHOME", stdlib, 1)
        setenv("PYTHONPATH", "\(stdlib):\(sitePackages)", 1)
        // Beeware recommendations: keep things deterministic + isolated.
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        // iOS has no DNS resolv.conf; aiohttp/asyncio default loop is fine.

        // PythonKit lazy-loads libpython; the dylib lives inside
        // Python.xcframework/<slice>/Python.framework/Python.
        // The xcframework is embedded into the app bundle so the
        // dynamic linker finds it via @rpath at launch. Python failures
        // raise a runtime trap (PythonKit doesn't bridge to Swift's
        // throws system) so we have no catch path here.
        let sys = Python.import("sys")
        _ = sys.version

        installEdgeTransport()

        initialized = true
    }

    // MARK: - Edge-TTS transport wiring

    /// Registers `EdgeTTSBridge` as the active Edge-TTS transport on
    /// the Python side via `python_app.src.tts._edge_transport.set_transport`.
    ///
    /// After this, any Python code that calls
    /// `_edge_transport.synthesize_chunk(text, voice)` -- in
    /// particular `ios_entrypoints.synthesize_chapter_via_transport` --
    /// will hit our `URLSessionWebSocketTask` instead of the default
    /// `edge_tts.Communicate` driver (which can't run on iOS because
    /// aiohttp's `_socket` extension won't `dlopen`).
    ///
    /// Failures are swallowed: if the embedded site-packages doesn't
    /// contain `python_app.src.tts._edge_transport` (e.g. running
    /// against an older bundle), iOS still has a working synthesis
    /// path via `convertWithEdgeTTS` -> `EdgeTTSBridge` directly. The
    /// Python pipeline is the upgrade; the direct bridge is the
    /// fallback.
    private func installEdgeTransport() {
        let transportModule: PythonObject
        do {
            transportModule = try Python.attemptImport(
                "python_app.src.tts._edge_transport"
            )
        } catch {
            // Older bundles without ios_entrypoints + _edge_transport
            // — fall back to the direct EdgeTTSBridge path.
            return
        }

        // Swift closure -> Python callable. PythonKit's `PythonFunction`
        // initializer expects `(PythonObject) throws -> PythonObject`,
        // receiving args as a Python tuple. We crack two positional args:
        // (text: str, voice: str), drive `EdgeTTSBridge.synthesize`
        // synchronously via DispatchSemaphore, and return Python `bytes`.
        //
        // Sync wrapping is deliberate: Python's transport contract is
        // sync (see `_edge_transport.synthesize_chunk`). Blocking one
        // Python thread per chunk is fine — chapter parallelism happens
        // at a higher level in `converter.py`, not inside a chunk.
        let bridge = EdgeTTSBridge()
        let fn = PythonFunction { args -> PythonObject in
            let text = String(args[0]) ?? ""
            let voice = String(args[1]) ?? ""
            let sem = DispatchSemaphore(value: 0)
            var outcome: Result<Data, Error> = .failure(
                EdgeTTSBridgeError.webSocketFailed("uninitialised")
            )
            Task.detached(priority: .userInitiated) {
                do {
                    let mp3 = try await bridge.synthesize(
                        text: text, voice: voice
                    )
                    outcome = .success(mp3)
                } catch {
                    outcome = .failure(error)
                }
                sem.signal()
            }
            sem.wait()
            switch outcome {
            case .success(let data):
                // PythonKit can convert `[UInt8]` to a Python list; we
                // wrap it in `bytes(...)` so the Python side gets a
                // proper bytes object (what edge_tts would have
                // returned).
                let pyBytes = Python.bytes(Python.list(Array(data)))
                return pyBytes
            case .failure(let err):
                // Raise on the Python side. `PythonError` exists in
                // PythonKit; throwing here propagates as a Python
                // exception, which `ios_entrypoints` will let bubble
                // up to Swift as a PythonKit trap unless caught.
                let msg = "EdgeTTSBridge: \(err)"
                return Python.import("builtins").RuntimeError(msg)
            }
        }
        let pyFn = fn.pythonObject

        edgeTransport = pyFn
        _ = transportModule.set_transport(pyFn)
    }

    // MARK: - Edge-TTS one-shot synth

    /// Synthesizes `text` with the given Edge voice and writes a single
    /// MP3 into `outputDir`. Returns the resulting file URL.
    ///
    /// Architecture: Swift owns the network (URLSession +
    /// URLSessionWebSocketTask via EdgeTTSBridge); Python is kept in the
    /// call signature for parity with the desktop pipeline but no longer
    /// participates in synthesis. This bypasses the aiohttp -> _socket
    /// dependency chain that iOS refuses to dlopen.
    func convertWithEdgeTTS(text: String, voice: String, outputDir: URL) async throws -> URL {
        // Bootstrap is best-effort: even if Python isn't available we can
        // still synthesize, since the bridge owns the network. We swallow
        // bootstrap failures here so simulator runs without the vendored
        // Python.xcframework still work for the synth smoke test.
        do { try bootstrap() } catch { /* fall through — Python not used in this path */ }

        let outputURL = outputDir
            .appendingPathComponent("edge_\(UUID().uuidString).mp3")

        do {
            let mp3 = try await EdgeTTSBridge().synthesize(text: text, voice: voice)
            try mp3.write(to: outputURL)
        } catch {
            throw PythonEmbedError.edgeSynthFailed("\(error)")
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PythonEmbedError.outputFileMissing(outputURL.path)
        }
        return outputURL
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
