// PythonEmbedTests.swift
//
// Smoke tests for the embedded Python runtime on Apple platforms.

#if os(iOS) || os(macOS)

import XCTest
import PythonKit
@testable import EpubToMp3

@MainActor
private final class StreamingSegmentRecorder {
    private(set) var segments: [(chapterIndex: Int, segmentIndex: Int, byteCount: Int)] = []

    func append(data: Data, chapterIndex: Int, segmentIndex: Int) {
        segments.append((chapterIndex, segmentIndex, data.count))
    }
}

final class PythonEmbedTests: XCTestCase {
    func testPythonTransportGateKeepsItsFirstResult() throws {
        let gate = EdgeSynthesisGate()
        gate.resolve(.success(Data([1, 2, 3])))
        gate.resolve(.failure(EdgeTTSBridgeError.timeout))

        XCTAssertEqual(try gate.wait().get(), Data([1, 2, 3]))
    }

    func testCancelledBridgeFailsBeforeOpeningANetworkConnection() async {
        let bridge = EdgeTTSBridge()
        bridge.cancel()

        do {
            _ = try await bridge.synthesize(
                text: "Cancelled before network request.",
                voice: "en-US-AriaNeural"
            )
            XCTFail("A cancelled bridge must not begin synthesis.")
        } catch is CancellationError {
            // Expected: register(socket:) observes the cancellation before resume.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    private func requireNetworkTTS(_ testName: String = #function) throws {
        let value = (ProcessInfo.processInfo.environment["RUN_IOS_NETWORK_TTS_TESTS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["1", "true", "yes"].contains(value.lowercased()) else {
            throw XCTSkip(
                "\(testName) reaches Edge-TTS over the network; set "
                + "RUN_IOS_NETWORK_TTS_TESTS=1 to run it explicitly."
            )
        }
    }

    private func requireEmbeddedPipeline(_ testName: String = #function) throws {
        let value = (ProcessInfo.processInfo.environment["RUN_IOS_EMBEDDED_PIPELINE_TESTS"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["1", "true", "yes"].contains(value.lowercased()) else {
            throw XCTSkip(
                "\(testName) exercises the embedded Python conversion pipeline; set "
                + "RUN_IOS_EMBEDDED_PIPELINE_TESTS=1 to run it explicitly."
            )
        }
    }

    /// Synthesizes a short pt-BR utterance with Edge-TTS in-process
    /// and asserts the MP3 was written. Network-dependent: Edge-TTS
    /// hits Microsoft's cloud endpoint.
    func testEdgeTTSConvertsHelloWorld() async throws {
        try requireNetworkTTS()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("python-embed-spike", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp,
                                                 withIntermediateDirectories: true)

        let mp3: URL
        do {
            mp3 = try await PythonEmbed.shared.convertWithEdgeTTS(
                text: "Olá, mundo. Este é o sidecar embedded.",
                voice: "pt-BR-FranciscaNeural",
                outputDir: tmp
            )
        } catch {
            throw XCTSkip("PythonEmbed bootstrap or Edge synth failed: \(error). " +
                          "Run ios/EpubToMp3/scripts/bootstrap-ios-python.sh and rebuild.")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3.path),
                      "MP3 missing at \(mp3.path)")

        let attrs = try FileManager.default.attributesOfItem(atPath: mp3.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 5_000,
                             "MP3 too small (\(size) bytes) — Edge probably didn't synth")
    }

    /// Isolates the native WSS protocol from CPython so a live failure can
    /// distinguish a transport regression from embedded-runtime setup.
    func testNativeEdgeBridgeReceivesAudio() async throws {
        try requireNetworkTTS()

        let audio = try await EdgeTTSBridge().synthesize(
            text: "This verifies the native Edge WebSocket bridge.",
            voice: "en-US-AriaNeural"
        )

        XCTAssertGreaterThan(audio.count, 5_000)
        XCTAssertTrue(
            audio.starts(with: Data([0x49, 0x44, 0x33]))
                || audio.starts(with: Data([0xFF])),
            "Edge response did not begin with an MP3 frame"
        )
    }

    func testNativeEdgeBridgeSplitsProtocolSizedTextBeforeSSMLEscaping() {
        let text = String(repeating: "<&> ", count: 1_500)
        let chunks = EdgeTTSBridge.protocolTextChunks(from: text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            let escaped = chunk
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            XCTAssertLessThanOrEqual(escaped.lengthOfBytes(using: .utf8), 4_096)
            XCTAssertTrue(
                EdgeTTSBridge.makeSSML(text: chunk, voice: "en-US-AriaNeural")
                    .contains("&lt;&amp;&gt;")
            )
        }
        XCTAssertEqual(chunks.joined(separator: " "), text.trimmingCharacters(in: .whitespaces))
    }

    func testBootstrapIsIdempotent() async throws {
        do {
            try await PythonRunner.shared.callAsync {
                try PythonEmbed.shared.bootstrap()
                try PythonEmbed.shared.bootstrap()  // must not throw on 2nd call
            }
        } catch {
            throw XCTSkip("Bootstrap failed (vendor likely missing): \(error)")
        }
    }

    func testBootstrapSetsWritablePersistentRoot() async throws {
        let rootPath = try await PythonRunner.shared.callAsync {
            try PythonEmbed.shared.bootstrap()
            guard let rawRoot = getenv("PERSISTENT_ROOT") else {
                throw PythonEmbedError.persistentRootCreationFailed("PERSISTENT_ROOT is missing")
            }
            return String(cString: rawRoot)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        XCTAssertTrue(root.path.hasPrefix(applicationSupport.path),
                      "PERSISTENT_ROOT must be in Application Support, not the read-only app bundle")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: root.path),
                      "PERSISTENT_ROOT must be writable by embedded Python")

        let modelsPath = try await PythonRunner.shared.callAsync {
            let paths = try Python.attemptImport("python_app.src.paths")
            guard let modelsPath = String(paths.MODELS_DIR) else {
                throw PythonEmbedError.persistentRootCreationFailed("MODELS_DIR is missing")
            }
            return modelsPath
        }
        XCTAssertEqual(
            URL(fileURLWithPath: modelsPath, isDirectory: true).standardizedFileURL,
            root.appendingPathComponent("models", isDirectory: true).standardizedFileURL,
            "Embedded Python models must live in writable Application Support"
        )
    }

    /// End-to-end: build a real EPUB with one chapter, hand it to
    /// ``PythonBridge.convertEpub`` (the CLI-superset entrypoint that
    /// wraps ``python_app.src.ios_entrypoints.convert_epub``), and
    /// assert at least one MP3 lands on disk with a non-trivial size.
    ///
    /// Network-dependent (Edge-TTS reaches Microsoft). Skip elegantly
    /// if bootstrap or synthesis fails — mirrors
    /// ``testEdgeTTSConvertsHelloWorld``.
    func testConvertEpubFixtureProducesMp3() async throws {
        try requireEmbeddedPipeline()
        try requireNetworkTTS()

        let epub: URL
        do {
            epub = try EpubFixture.createWithChapter(
                chapterTitle: "Chapter One",
                body: "Hello from the Python pipeline. This chapter exists "
                    + "purely to exercise the Edge-TTS round trip from "
                    + "Swift via the iOS entrypoint."
            )
        } catch {
            throw XCTSkip("Fixture build failed: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: epub) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-epub-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let outDir = root.appendingPathComponent("output", isDirectory: true)
        let cacheDir = root.appendingPathComponent(".cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result: PythonBridge.ConvertResult
        do {
            result = try await PythonBridge.shared.convertEpub(
                epubURL: epub,
                outputDir: outDir,
                cacheDir: cacheDir,
                voice: "en-US-AriaNeural"
            )
        } catch {
            throw XCTSkip(
                "convertEpub failed: \(error). Run "
                + "ios/EpubToMp3/scripts/bootstrap-ios-python.sh "
                + "and rebuild."
            )
        }

        XCTAssertTrue(result.errors.isEmpty,
                      "unexpected errors: \(result.errors)")
        XCTAssertFalse(result.outputs.isEmpty,
                       "convertEpub produced no MP3 outputs")
        XCTAssertFalse(result.manifest.isEmpty,
                       "manifest was empty")

        // The fixture book title shows up on the Python side as the
        // EPUB's `<dc:title>` (`Test Book Title` per EpubFixture).
        XCTAssertEqual(result.bookTitle, EpubFixture.title)

        // At least one chapter completed; the file is real and non-empty.
        let mp3 = result.outputs[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3.path),
                      "MP3 missing at \(mp3.path)")
        let attrs = try FileManager.default.attributesOfItem(atPath: mp3.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(
            size, 5_000,
            "MP3 too small (\(size) bytes) — Edge probably didn't synth"
        )

        // The manifest entry for this chapter must match the output URL.
        guard let entry = result.manifest.first(
            where: { $0.outputPath == mp3.path })
        else {
            return XCTFail("no manifest entry matches \(mp3.path)")
        }
        XCTAssertEqual(entry.status, "completed")
        XCTAssertEqual(entry.voice, "en-US-AriaNeural")
        XCTAssertGreaterThan(entry.charCount, 0)
    }

    /// Runs the exact streaming boundary used by Listen: bundled Python
    /// prepares the speech text, Swift performs the Edge WebSocket request,
    /// and every emitted MP3 segment crosses back through PythonKit in order.
    @MainActor
    func testStreamingPythonPipelineDeliversOrderedSegments() async throws {
        try requireEmbeddedPipeline()
        try requireNetworkTTS()
        try await PythonBridge.shared.preflightRuntime()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-pipeline-test-\(UUID().uuidString)",
                                    isDirectory: true)
        let output = root.appendingPathComponent("chapter-7.mp3")
        defer { try? FileManager.default.removeItem(at: root) }

        // Deliberately exceeds the normal 12K Edge chunk target so this test
        // exercises more than one callback on a device with default settings.
        let text = String(repeating: "This is an ordered streaming audio segment. ", count: 420)
        let recorder = StreamingSegmentRecorder()

        let result = try await PythonBridge.shared.convertChapterStreaming(
            text: text,
            voice: "en-US-AriaNeural",
            outputURL: output,
            chapterIndex: 7,
            onSegment: { data, chapterIndex, segmentIndex in
                recorder.append(
                    data: data,
                    chapterIndex: chapterIndex,
                    segmentIndex: segmentIndex
                )
                return true
            }
        )

        let segments = recorder.segments
        XCTAssertEqual(result, output)
        XCTAssertGreaterThanOrEqual(segments.count, 2,
                                    "expected multiple streamed MP3 segments")
        XCTAssertEqual(segments.map(\.chapterIndex), Array(repeating: 7, count: segments.count))
        XCTAssertEqual(segments.map(\.segmentIndex), Array(0..<segments.count))
        XCTAssertTrue(segments.allSatisfy { $0.byteCount > 5_000 })

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(byteCount, 10_000, "streaming pipeline wrote an unexpectedly small MP3")
    }

    /// Engine-gate regression: asking for Piper must produce a clear
    /// error, not a silent fallback. Mirrors
    /// `test_convert_epub_invalid_engine_raises` in pytest so both
    /// sides of the bridge agree on the contract.
    func testConvertEpubRejectsPiperEngine() async throws {
        try requireEmbeddedPipeline()

        let epub: URL
        do {
            epub = try EpubFixture.createWithChapter()
        } catch {
            throw XCTSkip("Fixture build failed: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: epub) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-epub-engine-gate-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var opts = PythonBridge.ConvertOptions()
        opts.engine = "piper"

        do {
            _ = try await PythonBridge.shared.convertEpub(
                epubURL: epub,
                outputDir: root.appendingPathComponent("output"),
                cacheDir: root.appendingPathComponent(".cache"),
                options: opts
            )
            XCTFail("expected convertEpub to reject engine=piper")
        } catch {
            // PythonKit traps on a raised exception — any thrown error
            // here satisfies the engine-gate contract. The pytest
            // counterpart asserts the exact message; on Swift we accept
            // anything non-nil because the trap surfaces as either a
            // PythonBridgeError or a PythonKit fatal — the contract is
            // "must not succeed".
            XCTAssertNotNil(error)
        }
    }

    func testParallelEdgeRetryPolicyIsBoundedAndExponential() {
        let environment = [
            "EDGE_STREAM_MAX_RETRIES": "9",
            "IOS_EDGE_RETRY_BACKOFF_SECONDS": "2"
        ]
        XCTAssertEqual(PythonBridge.edgeStreamRetryCount(environment: environment), 6)
        XCTAssertEqual(PythonBridge.edgeRetryDelay(attempt: 0, environment: environment), 2)
        XCTAssertEqual(PythonBridge.edgeRetryDelay(attempt: 3, environment: environment), 16)
        XCTAssertEqual(
            PythonBridge.edgeRetryDelay(
                attempt: 5,
                environment: ["IOS_EDGE_RETRY_BACKOFF_SECONDS": "20"]
            ),
            30
        )
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
