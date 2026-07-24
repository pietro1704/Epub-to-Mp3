// MacEpubParser.swift
//
// macOS-only counterpart of iOS's `PythonBridge.parseEpub`. iOS uses
// in-process PythonKit + Python.xcframework; macOS runs the same
// `python_app.src.android_entrypoints.parse_epub_to_json` through a
// short-lived `python3` subprocess. Both end up returning the exact
// same `EbookFulltext` shape (table-of-contents + chapter text), so
// the rest of the app's native reader does not care which
// platform produced it.
//
// Why subprocess instead of embedding via PythonKit: macOS already
// ships system `/usr/bin/python3` (and a venv-managed copy via mise).
// Embedding Python.xcframework on macOS would buy nothing over a fork
// and would force every app-bundle to drag ~150 MB of CPython along.
// The subprocess is invoked once per "Open EPUB" — cold-start ~150 ms,
// trivial vs. the time the user already spent picking a file.

#if os(macOS) && !targetEnvironment(simulator)

import Foundation

enum MacEpubParserError: Error, LocalizedError {
    case pythonNotFound
    case pythonAppMissing(String)
    case parseFailed(stderr: String, exitCode: Int32)
    case emptyOutput
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "python3 not found on PATH. Install Xcode Command Line Tools or run `mise use -g python@3.13`."
        case .pythonAppMissing(let path):
            return "python_app/ not found at \(path). The macOS bundle should ship python_app under Resources; rebuild via `mise run mac:build`."
        case .parseFailed(let err, let code):
            return "EPUB parser exited with code \(code): \(err.prefix(280))"
        case .emptyOutput:
            return "EPUB parser returned empty output."
        case .decodeFailed(let msg):
            return "Failed to decode parsed EPUB JSON: \(msg)"
        }
    }
}

enum MacEpubParser {

    /// Parses the EPUB at `fileURL` using the same Python pipeline the
    /// iOS app + HF backend run. Synchronously launches `python3` as a
    /// subprocess and decodes its stdout JSON.
    static func parse(at fileURL: URL, bookId: String) async throws -> EbookFulltext {
        try await Task.detached(priority: .userInitiated) {
            try parseSync(fileURL: fileURL, bookId: bookId)
        }.value
    }

    // MARK: - Sync core

    private static func parseSync(fileURL: URL, bookId: String) throws -> EbookFulltext {
        let pythonURL = try resolvePython3()
        let pythonAppRoot = try resolvePythonAppRoot()

        let task = Process()
        task.executableURL = pythonURL
        // Run the iOS-/Android-shared entrypoint. `-c` keeps the
        // script out-of-tree so no temp file is needed; the path is
        // piped via stdin (avoids shell-quoting issues on filenames
        // with quotes / non-ASCII).
        task.arguments = [
            "-I",                 // isolated mode — ignore PYTHONHOME/user site
            "-S",                 // skip site.py — pulls in less stdlib
            "-c", """
            import sys, os, json
            sys.path.insert(0, os.environ['PYTHONPATH'])
            from python_app.src.android_entrypoints import parse_epub_to_dict
            path = sys.stdin.read().strip()
            print(json.dumps(parse_epub_to_dict(path), ensure_ascii=False))
            """,
        ]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pythonAppRoot.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        task.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        task.standardInput = stdinPipe

        do { try task.run() } catch {
            throw MacEpubParserError.parseFailed(
                stderr: "Process.run failed: \(error)", exitCode: -1)
        }

        // Feed the EPUB path to stdin and close so Python's read()
        // unblocks.
        let pathBytes = (fileURL.path + "\n").data(using: .utf8) ?? Data()
        try? stdinPipe.fileHandleForWriting.write(contentsOf: pathBytes)
        try? stdinPipe.fileHandleForWriting.close()

        task.waitUntilExit()

        let exitCode = task.terminationStatus
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        guard exitCode == 0 else {
            throw MacEpubParserError.parseFailed(stderr: stderrStr, exitCode: exitCode)
        }
        guard !stdoutData.isEmpty else {
            throw MacEpubParserError.emptyOutput
        }

        do {
            let decoder = JSONDecoder()
            let raw = try decoder.decode(EbookFulltext.self, from: stdoutData)
            // The Python entrypoint sets jobId from its `book_id`
            // arg if provided, but `parse_epub_to_dict` defaults to
            // empty. Stamp it here so the cache key lines up with
            // the rest of the app.
            return EbookFulltext(
                jobId: bookId.isEmpty ? raw.jobId : bookId,
                bookTitle: raw.bookTitle,
                bookAuthor: raw.bookAuthor,
                chapters: raw.chapters
            )
        } catch {
            throw MacEpubParserError.decodeFailed("\(error)")
        }
    }

    // MARK: - Path resolution

    /// Find a usable `python3` on the host. Order:
    ///   1. `/usr/bin/python3` (Xcode CLT — always present)
    ///   2. `python3` on PATH (mise / Homebrew / pyenv)
    private static func resolvePython3() throws -> URL {
        let cltPath = URL(fileURLWithPath: "/usr/bin/python3")
        if FileManager.default.isExecutableFile(atPath: cltPath.path) {
            return cltPath
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { throw MacEpubParserError.pythonNotFound }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else {
            throw MacEpubParserError.pythonNotFound
        }
        return URL(fileURLWithPath: out)
    }

    /// Find `python_app/` on disk. In a `mise run mac:build` bundle it
    /// lives at `<App>.app/Contents/Resources/python_app`. In a dev
    /// build (no post-build copy) we fall back to the repo checkout
    /// resolved via the bundle's location.
    private static func resolvePythonAppRoot() throws -> URL {
        let bundle = Bundle.main
        // 1. App-bundle resource (built via mac:build's post-build).
        if let bundled = bundle.url(forResource: "python_app", withExtension: nil),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // 2. Repo checkout — walk up from the bundle to find python_app/.
        var dir = bundle.bundleURL
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("python_app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir   // PYTHONPATH points at the parent so `import python_app` works
            }
            dir.deleteLastPathComponent()
        }
        throw MacEpubParserError.pythonAppMissing(bundle.bundleURL.path)
    }
}

#endif  // os(macOS) && !targetEnvironment(simulator)
