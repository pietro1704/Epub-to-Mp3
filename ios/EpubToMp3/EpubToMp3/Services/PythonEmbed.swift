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

        initialized = true
    }

    // MARK: - Edge-TTS one-shot synth

    /// Synthesizes `text` with the given Edge voice and writes a single
    /// MP3 into `outputDir`. Returns the resulting file URL.
    ///
    /// Hacky-on-purpose: no streaming, no SSE, no chunking. This proves
    /// the path; the production version will mirror server.py.
    func convertWithEdgeTTS(text: String, voice: String, outputDir: URL) async throws -> URL {
        try bootstrap()

        let outputPath = outputDir
            .appendingPathComponent("edge_\(UUID().uuidString).mp3")
            .path

        // PythonKit calls don't throw to Swift — Python exceptions surface
        // as runtime traps. Run on a detached task so the GIL release/
        // acquire doesn't block the actor we were called from.
        await Task.detached(priority: .userInitiated) {
            let asyncio = Python.import("asyncio")
            let edgeTTS = Python.import("edge_tts")

            // Build the coroutine in Python, then asyncio.run() it.
            // edge_tts.Communicate(text, voice).save(path) returns a
            // coroutine because .save is `async def`.
            let comm = edgeTTS.Communicate(text, voice)
            let coro = comm.save(outputPath)
            _ = asyncio.run(coro)
        }.value

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw PythonEmbedError.outputFileMissing(outputPath)
        }
        return URL(fileURLWithPath: outputPath)
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
