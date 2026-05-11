// PythonBridge.swift
//
// Thin Swift wrappers around the canonical Python pipeline modules
// embedded in the iOS bundle (see `python_app/src/`). Calling into
// these from Swift means the iOS app, the macOS sidecar, and the HF
// Spaces backend all run the SAME parser / cache / chunker / validator
// code. No more Swift reimplementations of EPUB parsing.
//
// Network I/O remains in Swift (`EdgeTTSBridge.swift`,
// `URLSessionWebSocketTask`) because iOS cannot `dlopen` libpython's
// `_socket`/`_ssl` extensions. The Edge-TTS path injects bytes back
// into Python only for retry/validation orchestration; that wiring is
// scoped for a follow-up slice.
//
// Bootstrap requirements (run once before building):
//   ios/EpubToMp3/scripts/bootstrap-ios-python.sh
//
// macOS still uses the sidecar path (`SidecarManager.swift`). This
// file only compiles on iOS / simulator.

#if os(iOS) || targetEnvironment(simulator)

import Foundation
import PythonKit

enum PythonBridgeError: Error, LocalizedError {
    case bootstrapFailed(String)
    case parseFailed(String)
    case decodeFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let m): return "Python bootstrap failed: \(m)"
        case .parseFailed(let m): return "Python parse failed: \(m)"
        case .decodeFailed(let m): return "Python result decode failed: \(m)"
        case .emptyResult: return "Python parser produced no chapters"
        }
    }
}

/// Synchronisation gate around in-process Python calls. PythonKit
/// surfaces CPython through a single interpreter, which is not
/// thread-safe; we serialise calls on a dedicated dispatch queue so
/// concurrent SwiftUI `Task`s don't race on the GIL boundary.
final class PythonBridge: @unchecked Sendable {
    static let shared = PythonBridge()

    /// Serial — `PythonKit` is not thread-safe. Cheap to bounce work
    /// here because parsing a typical EPUB takes a few hundred ms.
    private let queue = DispatchQueue(
        label: "epub2mp3.python-bridge", qos: .userInitiated
    )

    private init() {}

    // MARK: - EPUB parse

    /// Parses an EPUB on disk via `python_app.src.ebook_reader.parse_epub_to_dict`,
    /// the same function the macOS sidecar exposes through
    /// `GET /api/jobs/{id}/fulltext`. Returns an `EbookFulltext` already
    /// decoded into the model the SwiftUI reader expects — same wire
    /// shape, same code path, no Swift-side parser to maintain.
    ///
    /// - Parameters:
    ///   - fileURL: on-disk location of the `.epub`.
    ///   - bookId: SHA-256 content hash from `LibraryStore`; propagated
    ///     as `EbookFulltext.jobId` so downstream caches keyed on
    ///     `jobId` line up with what the backend would have returned.
    /// - Throws: `PythonBridgeError` if bootstrap, parse, or JSON
    ///   decode fails.
    func parseEpub(at fileURL: URL, bookId: String) async throws -> EbookFulltext {
        try PythonEmbed.shared.bootstrap()

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.parseEpubSync(
                        path: fileURL.path, bookId: bookId
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Same as `parseEpub(at:bookId:)` but synchronous. Marked private
    /// because callers MUST land on `queue` first to avoid GIL races.
    private func parseEpubSync(path: String, bookId: String) throws -> EbookFulltext {
        // PythonKit traps on its own errors; the `Python.attemptImport`
        // surface is the safest entry point. Anything else (`Python.import`)
        // raises a fatalError on import failure — not catchable.
        let reader: PythonObject
        do {
            reader = try Python.attemptImport("python_app.src.ebook_reader")
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ebook_reader: \(error)"
            )
        }

        let pyResult = reader.parse_epub_to_dict(path, bookId)

        // Cross the Swift boundary as JSON. The Python helper already
        // emits keys that match `EbookFulltext`'s `Codable` shape; we
        // just need a serialisable container.
        let json: PythonObject
        do {
            json = try Python.attemptImport("json")
        } catch {
            throw PythonBridgeError.decodeFailed("import json: \(error)")
        }
        guard let jsonText = String(json.dumps(pyResult)) else {
            throw PythonBridgeError.decodeFailed("json.dumps returned non-string")
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw PythonBridgeError.decodeFailed("UTF-8 encode failed")
        }
        let decoded: EbookFulltext
        do {
            decoded = try JSONDecoder().decode(EbookFulltext.self, from: data)
        } catch {
            throw PythonBridgeError.decodeFailed("\(error)")
        }
        guard !decoded.chapters.isEmpty else {
            throw PythonBridgeError.emptyResult
        }
        return decoded
    }

    // MARK: - Chapter conversion (Python pipeline + Swift transport)

    /// Synthesises one chapter through the canonical Python pipeline.
    ///
    /// Internally calls
    /// `python_app.src.ios_entrypoints.synthesize_chapter_via_transport`,
    /// which chunks `text` and invokes the currently-installed Edge-TTS
    /// transport per chunk. `PythonEmbed.bootstrap()` registers
    /// `EdgeTTSBridge` as that transport at app launch, so on iOS the
    /// chunks go out over `URLSessionWebSocketTask` (Swift owns the
    /// socket) while Python keeps owning the orchestration (chunking,
    /// validation, future retry / fallback).
    ///
    /// This replaces the direct `EdgeTTSBridge().synthesize(...)` path
    /// that `PythonEmbed.convertWithEdgeTTS` used during the spike --
    /// the iOS app and the macOS sidecar now share a single conversion
    /// pipeline, the only difference being which transport is wired
    /// into `_edge_transport`.
    func convertChapter(
        text: String, voice: String, outputDir: URL
    ) async throws -> URL {
        try PythonEmbed.shared.bootstrap()

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let url = try self.convertChapterSync(
                        text: text, voice: voice, outputDir: outputDir
                    )
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func convertChapterSync(
        text: String, voice: String, outputDir: URL
    ) throws -> URL {
        let outURL = outputDir.appendingPathComponent(
            "edge_\(UUID().uuidString).mp3"
        )
        try FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true
        )

        let entry: PythonObject
        do {
            entry = try Python.attemptImport(
                "python_app.src.ios_entrypoints"
            )
        } catch {
            throw PythonBridgeError.bootstrapFailed(
                "import python_app.src.ios_entrypoints: \(error)"
            )
        }

        // `synthesize_chapter_via_transport(text, voice, out_path) -> str`.
        // PythonKit traps on a raised Python exception; the Swift caller
        // sees a runtime crash if Edge fails, which matches the existing
        // PythonBridge.parseEpub contract. We surface a wrapped error
        // only for missing-file / decode-style issues we can detect
        // from Swift.
        _ = entry.synthesize_chapter_via_transport(
            text, voice, outURL.path
        )

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw PythonBridgeError.parseFailed(
                "ios_entrypoints did not write \(outURL.path)"
            )
        }
        return outURL
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
