// PiperBridge.swift
//
// Slice 1b (stub-only): Swift seam for the offline Piper TTS engine
// on iOS. Mirrors EdgeTTSBridge.swift in shape so the Python side can
// install it via ``python_app.src.tts._piper_transport.set_transport``
// at boot and the wider pipeline can use ``fallback_engine="piper"``
// without further branching.
//
// **No synthesis happens here yet.** Every call throws
// ``PiperBridgeError.notImplemented``. The bring-up plan in
// ``ios/PIPER-EMBED.md`` lists the three C dependencies that have to
// be cross-compiled for iOS arm64 (device + simulator) before this
// file can become a real engine:
//
//   1. onnxruntime — Microsoft ships ``onnxruntime-objc`` via SPM; the
//      easiest of the three.
//   2. espeak-ng — Piper feeds phoneme IDs from espeak-ng's text
//      analyser. No iOS build vendored.
//   3. lame — Piper outputs WAV float arrays; the transport contract
//      is MP3 bytes, so we'll need an MP3 encoder on the Swift side.
//
// When those land, this file replaces ``.notImplemented`` with the
// real flow: load the appropriate ``.onnx`` model for ``language``
// from ``Vendor/piper-models/``, run inference, encode to MP3,
// return Data. The pytest + XCTest suites already pin the
// engine-gate contract so the seam swap is safe.

import Foundation

/// Languages whose Piper voice models we plan to ship in slice 1b:
///   - pt-BR: pt_BR-faber-medium.onnx
///   - en-US: en_US-amy-medium.onnx
///
/// All entries currently route to ``.notImplemented`` — the list
/// exists so the Swift caller can introspect supported languages
/// without invoking the (failing) bridge, and so the test suite has
/// a stable surface to assert against.
enum PiperBridgeLanguage: String, CaseIterable {
    case ptBR = "pt-BR"
    case enUS = "en-US"
}

enum PiperBridgeError: Error, LocalizedError {
    /// Language tag is outside ``PiperBridgeLanguage`` (we have no
    /// vendored ``.onnx`` model for it).
    case unsupportedLanguage(String)
    /// Model lookup hit a known language but the ``.onnx`` file was
    /// missing from the bundle (build-time fetch failed or was
    /// skipped).
    case modelNotLoaded(String)
    /// Stub-only slice. Means: code path reached the bridge, found a
    /// supported language and a model, but no actual ONNX/espeak/MP3
    /// pipeline has been wired in yet.
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let tag):
            return "PiperBridge: language \(tag) not supported (see PiperBridgeLanguage)"
        case .modelNotLoaded(let tag):
            return "PiperBridge: model for \(tag) not present in bundle"
        case .notImplemented:
            return "Piper iOS requires onnxruntime + espeak-ng + lame "
                + "cross-compile (see ios/PIPER-EMBED.md)"
        }
    }
}

/// Stub bridge that the Python pipeline can install as the Piper
/// transport via ``_piper_transport.set_transport``. Until the C
/// dependencies are vendored, ``synthesize`` always throws
/// ``PiperBridgeError.notImplemented`` so the seam is observable but
/// inert -- exactly the "installed but never succeeds" state the
/// slice 1b brief calls for.
///
/// Concurrency: ``@unchecked Sendable`` mirrors ``EdgeTTSBridge``.
/// The class holds no mutable state today; when real synthesis lands
/// it will own an ``ORTSession`` per language, which is itself
/// thread-safe per Microsoft's docs but does not bridge cleanly to
/// Swift's actor model.
final class PiperBridge: @unchecked Sendable {

    /// Supported language tags. Static so callers (Swift settings UI,
    /// PythonEmbed bootstrap diagnostics) can enumerate them without
    /// instantiating the bridge.
    static let supportedLanguages: [String] = PiperBridgeLanguage.allCases.map { $0.rawValue }

    init() {}

    /// Synthesize ``text`` into MP3 bytes for the given language.
    ///
    /// Today: always throws. The error type tells the caller which
    /// part of the bring-up is missing.
    func synthesize(text: String, language: String) async throws -> Data {
        let normalised = Self.normaliseLanguage(language)
        guard PiperBridgeLanguage(rawValue: normalised) != nil else {
            throw PiperBridgeError.unsupportedLanguage(language)
        }
        // Stub: bring-up not complete. Real implementation will:
        //   1. Locate <lang>.onnx in Bundle.main / Vendor/piper-models.
        //   2. Run onnxruntime inference producing float[] audio.
        //   3. Encode to MP3 via lame.
        //   4. Return Data.
        throw PiperBridgeError.notImplemented
    }

    /// Map any accepted spelling of a BCP-47 tag onto the canonical
    /// form used in ``PiperBridgeLanguage`` (``pt-BR``, ``en-US``).
    /// Handles ``pt_BR``, ``pt-br``, bare ``pt``/``en`` defaults, etc.
    /// Pure function so tests can pin the normalisation rules.
    static func normaliseLanguage(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        if trimmed.isEmpty { return trimmed }
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        let primary = parts[0].lowercased()
        if parts.count == 1 {
            // Bare primary tag — default to the region we plan to ship.
            switch primary {
            case "pt": return "pt-BR"
            case "en": return "en-US"
            default: return primary
            }
        }
        let region = parts[1].uppercased()
        return "\(primary)-\(region)"
    }
}
