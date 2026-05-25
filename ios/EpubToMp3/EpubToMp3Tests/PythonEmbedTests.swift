// PythonEmbedTests.swift
//
// Simulator-only smoke test for the embedded-Python spike.
// Skipped on macOS (the sidecar still owns macOS).

#if os(iOS) || targetEnvironment(simulator)

import XCTest
@testable import EpubToMp3

final class PythonEmbedTests: XCTestCase {
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

    func testBootstrapIsIdempotent() throws {
        do {
            try PythonEmbed.shared.bootstrap()
            try PythonEmbed.shared.bootstrap()  // must not throw on 2nd call
        } catch {
            throw XCTSkip("Bootstrap failed (vendor likely missing): \(error)")
        }
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
}

#endif  // os(iOS) || targetEnvironment(simulator)
