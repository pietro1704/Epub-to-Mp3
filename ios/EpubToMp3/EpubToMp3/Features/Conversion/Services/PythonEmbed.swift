// PythonEmbed.swift
//
// In-process CPython runtime shared by the native iOS and macOS apps.
// The Apple clients do not launch a second server process.
//
// Bootstrap requirements (run once before building):
//   ios/EpubToMp3/scripts/bootstrap-ios-python.sh
//
// See ios/PYTHON-EMBED.md for the full architecture write-up.

#if os(iOS) || os(macOS)

import Foundation
import PythonKit

enum PythonEmbedError: Error, LocalizedError {
    case stdlibMissing
    case sitePackagesMissing
    case persistentRootCreationFailed(String)
    case pythonInitFailed(String)
    case edgeSynthFailed(String)
    case outputFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .stdlibMissing: return "python-stdlib not found in app bundle"
        case .sitePackagesMissing: return "site-packages not found in app bundle"
        case .persistentRootCreationFailed(let m): return "unable to create embedded Python data directory: \(m)"
        case .pythonInitFailed(let m): return "Py_Initialize failed: \(m)"
        case .edgeSynthFailed(let m): return "Edge-TTS failed: \(m)"
        case .outputFileMissing(let p): return "MP3 not written at \(p)"
        }
    }
}

/// Bridges a synchronous Python callback to an async task without racing on
/// a captured mutable local. The callback waits on the semaphore, while the
/// detached task publishes the result from another thread.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Delivers exactly one result from an async Edge call to the synchronous
/// Python transport callback. Cancellation may resolve the gate before the
/// URLSession task has finished unwinding, so duplicate completion signals
/// must be ignored.
final class EdgeSynthesisGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: Result<Data, Error>?

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Result<Data, Error> {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return outcome ?? .failure(EdgeTTSBridgeError.webSocketFailed("missing synthesis result"))
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
    var isBootstrapComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized
    }
    /// Strong reference to the PythonKit closure object we install as
    /// the Edge-TTS transport. PythonKit wraps Swift closures in
    /// `PythonFunction`; if Swift drops its reference the Python side
    /// gets a dangling callback and segfaults the first time it fires.
    /// Holding the closure here for the interpreter's lifetime is
    /// cheap (one slot) and keeps the bridge alive.
    private(set) var edgeTransport: PythonObject?
    private let edgeInvocationLock = NSLock()
    private var activeEdgeBridge: EdgeTTSBridge?
    private var activeEdgeGate: EdgeSynthesisGate?
    /// Pre-imported `python_app.src.ios_entrypoints` module handle. We
    /// pin this during ``bootstrap()`` so the first chapter synthesis is
    /// a `sys.modules` cache hit instead of a fresh
    /// ``PyImport_ImportModule`` — the latter has been observed to crash
    /// inside ``_PyObject_Malloc`` -> ``PyUnicode_New`` ->
    /// ``unicode_decode_utf8`` on iOS when a worker thread different
    /// from the one that initialised the interpreter triggers the
    /// import machinery. Pre-importing on the bootstrap thread keeps the
    /// allocator state local to that thread.
    private(set) var iosEntrypoints: PythonObject?
    /// Pre-imported `python_app.src.ebook_reader` module — same
    /// rationale as ``iosEntrypoints``. Parsing is the very first
    /// Python call the iOS pipeline issues, and we want it to land on a
    /// hot `sys.modules` lookup, not a cold disk read + UTF-8 decode of
    /// the source file.
    private(set) var ebookReader: PythonObject?

    /// `true` once bootstrap completed AND `ebook_reader` imported
    /// successfully. When `false`, callers should surface a parse
    /// error or keep the cached fulltext instead of switching to a
    /// separate Swift parser.
    var isParserAvailable: Bool { ebookReader != nil }
    private(set) var parserImportFailure: String?

    private init() {}

    // MARK: - Bootstrap

    /// Finds the loaded bundle that owns the embedded runtime. `Bundle.main`
    /// is the app in production, but direct XCTest execution makes it the
    /// `xctest` host while the app bundle remains loaded separately.
    private func runtimeBundle() -> Bundle? {
        let candidates = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        return candidates.first { bundle in
            bundle.url(forResource: "python-stdlib", withExtension: nil) != nil
                && bundle.url(forResource: "site-packages", withExtension: nil) != nil
        }
    }

    /// Idempotent. Initializes CPython with PYTHONHOME / PYTHONPATH
    /// pointing at the bundled stdlib + site-packages.
    func bootstrap() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }

        guard let bundle = runtimeBundle() else {
            throw PythonEmbedError.stdlibMissing
        }

        guard let stdlib = bundle.path(forResource: "python-stdlib", ofType: nil) else {
            throw PythonEmbedError.stdlibMissing
        }
        guard let sitePackages = bundle.path(forResource: "site-packages", ofType: nil) else {
            throw PythonEmbedError.sitePackagesMissing
        }

        // PYTHONHOME must point at a directory containing `lib/python3.X`
        // OR be set alongside PYTHONPATH that explicitly lists the stdlib.
        // Beeware ships python-stdlib as the stdlib root. Because this is
        // not CPython's usual `lib/python3.X` layout, add `lib-dynload`
        // explicitly as well so built-in stdlib extensions such as `_struct`
        // and `zlib` resolve from the target-matched bundle slice.
        let dynamicModules = (stdlib as NSString).appendingPathComponent("lib-dynload")
        setenv("PYTHONHOME", stdlib, 1)
        setenv("PYTHONPATH", "\(stdlib):\(dynamicModules):\(sitePackages)", 1)
        // Beeware recommendations: keep things deterministic + isolated.
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        // The embedded package is inside the signed, read-only app bundle.
        // Python's cache/output/job roots must therefore live in the app's
        // writable Application Support container on both iOS and macOS.
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("EpubToMp3", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportRoot,
                                                    withIntermediateDirectories: true)
        } catch {
            throw PythonEmbedError.persistentRootCreationFailed(error.localizedDescription)
        }
        guard FileManager.default.isWritableFile(atPath: supportRoot.path) else {
            throw PythonEmbedError.persistentRootCreationFailed("directory is not writable: \(supportRoot.path)")
        }
        setenv("PERSISTENT_ROOT", supportRoot.path, 1)

        // PythonKit lazy-loads libpython via dlopen. If the framework
        // is missing (simulator without bootstrap), dlopen returns NULL
        // and PythonKit traps. Guard with a dlopen probe first so we
        // throw a recoverable error instead of crashing.
        let alreadyLoaded = dlopen("Python.framework/Python", RTLD_NOLOAD) != nil
        let loadedFromRPath = dlopen("@rpath/Python.framework/Python", RTLD_LAZY) != nil
        guard alreadyLoaded || loadedFromRPath else {
            throw PythonEmbedError.pythonInitFailed(
                "libpython not loadable — Python.xcframework missing from bundle"
            )
        }
        let sys = Python.import("sys")
        _ = sys.version

        installEdgeTransport()
        preloadHotModules()

        initialized = true
    }

    /// Pre-imports the Python modules the iOS pipeline will exercise on
    /// its hot path. Performed once, on the same thread that ran
    /// ``Py_Initialize``, so ``PyImport_ImportModule`` never has to run
    /// later from an arbitrary serial-queue worker — that path crashed
    /// inside ``_PyObject_Malloc`` when the import machinery's UTF-8
    /// source-file decode allocated against an unfamiliar thread's
    /// allocator state.
    ///
    /// Failures here are swallowed deliberately: the reader and TTS
    /// paths degrade independently, but the canonical EPUB parser is
    /// still the Python module imported above.
    private func preloadHotModules() {
        if iosEntrypoints == nil {
            do {
                iosEntrypoints = try Python.attemptImport("python_app.src.ios_entrypoints")
            } catch {}
        }
        if ebookReader == nil {
            do {
                ebookReader = try Python.attemptImport("python_app.src.ebook_reader")
                parserImportFailure = nil
            } catch {
                parserImportFailure = String(describing: error)
            }
        }
    }

    /// Lazily imports a module on the calling thread when the bootstrap
    /// preload didn't succeed (e.g. a transient hashlib/site-packages
    /// glitch). The serial Python queue (``PythonBridge.queue``) is the
    /// only legitimate caller — landing here from any other thread will
    /// still race the GIL.
    func ensureIosEntrypoints() throws -> PythonObject {
        if let cached = iosEntrypoints { return cached }
        let module = try Python.attemptImport("python_app.src.ios_entrypoints")
        iosEntrypoints = module
        return module
    }

    func ensureEbookReader() throws -> PythonObject {
        if let cached = ebookReader { return cached }
        let module = try Python.attemptImport("python_app.src.ebook_reader")
        ebookReader = module
        return module
    }

    /// Interrupts the WebSocket currently servicing the synchronous Python
    /// transport callback. Resolving its gate releases PythonRunner at once,
    /// which lets a replacement Listen request proceed instead of queuing
    /// behind the cancelled chapter.
    func cancelActiveEdgeSynthesis() {
        edgeInvocationLock.lock()
        let bridge = activeEdgeBridge
        let gate = activeEdgeGate
        activeEdgeBridge = nil
        activeEdgeGate = nil
        edgeInvocationLock.unlock()

        bridge?.cancel()
        gate?.resolve(.failure(CancellationError()))
    }

    private func registerActiveEdgeSynthesis(
        bridge: EdgeTTSBridge,
        gate: EdgeSynthesisGate
    ) {
        edgeInvocationLock.lock()
        activeEdgeBridge = bridge
        activeEdgeGate = gate
        edgeInvocationLock.unlock()
    }

    private func clearActiveEdgeSynthesis(for bridge: EdgeTTSBridge) {
        edgeInvocationLock.lock()
        if activeEdgeBridge === bridge {
            activeEdgeBridge = nil
            activeEdgeGate = nil
        }
        edgeInvocationLock.unlock()
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
        let fn = PythonFunction { args throws -> PythonObject in
            let text = String(args[0]) ?? ""
            let voice = String(args[1]) ?? ""
            let bridge = EdgeTTSBridge()
            let gate = EdgeSynthesisGate()
            self.registerActiveEdgeSynthesis(bridge: bridge, gate: gate)
            defer { self.clearActiveEdgeSynthesis(for: bridge) }
            Task.detached(priority: .userInitiated) {
                do {
                    // `EdgeTTSBridge` owns the request deadline (60 s) and
                    // its 15 s no-frame watchdog. A second 30 s deadline
                    // here cancelled healthy 12K-character chunks while
                    // they were still streaming audio.
                    let mp3 = try await bridge.synthesize(text: text, voice: voice)
                    gate.resolve(.success(mp3))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            switch gate.wait() {
            case .success(let data):
                return Python.bytes(Python.list(Array(data)))
            case .failure(let err):
                // Throw — PythonKit converts a Swift throw into a Python
                // exception on the calling thread. The previous code
                // *returned* a `RuntimeError` instance as if it were
                // bytes, which made `audio.extend(mp3)` silently truthy
                // or raise `TypeError` in `synthesize_chapter_streaming`,
                // depending on the chunk index — symptoms: no audio,
                // no clear failure log.
                throw PythonEmbedError.edgeSynthFailed("\(err)")
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
    /// type name for historical parity, but this method deliberately does
    /// not touch PythonKit or the embedded interpreter. That keeps the live
    /// simulator smoke test and fallback synthesis path independent from
    /// Python GIL/bootstrap state.
    func convertWithEdgeTTS(text: String, voice: String, outputDir: URL) async throws -> URL {
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
