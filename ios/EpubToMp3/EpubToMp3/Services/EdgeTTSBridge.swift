// EdgeTTSBridge.swift
//
// Native-Swift Edge-TTS client. Replaces aiohttp + edge_tts Python
// dependency for in-process iOS synthesis (branch: feat/ios-python-embed).
//
// Why this exists: iOS refuses to `dlopen` `.so` files outside of
// `.framework` bundles, so every CPython lib-dynload extension
// (_socket, _ssl, _hashlib, ...) silently fails to import. aiohttp
// transitively requires _socket, so the original Python-driven
// synthesis path is dead on iOS. Moving HTTP + WebSocket I/O into
// Swift (URLSessionWebSocketTask is a first-class iOS API) sidesteps
// the entire C-extension TCP/TLS chain.
//
// Protocol cribbed verbatim from rany2/edge-tts communicate.py:
//   wss://speech.platform.bing.com/consumer/speech/synthesize/
//          readaloud/edge/v1?TrustedClientToken=...
// Send: speech.config text frame, then SSML text frame.
// Receive: binary frames (header + MP3 chunk) + text frames; stop
// when we see `Path:turn.end` in a text frame.

import Foundation
import CryptoKit

enum EdgeTTSBridgeError: Error, LocalizedError {
    case webSocketFailed(String)
    case unexpectedFrame(String)
    case noAudioReceived
    case invalidBinaryFrame
    case timeout

    var errorDescription: String? {
        switch self {
        case .webSocketFailed(let m): return "WebSocket: \(m)"
        case .unexpectedFrame(let m): return "Unexpected frame: \(m)"
        case .noAudioReceived: return "Edge returned no audio"
        case .invalidBinaryFrame: return "Malformed binary frame"
        case .timeout: return "Edge synth timed out"
        }
    }
}

/// Thin async client around `URLSessionWebSocketTask` that speaks the
/// Microsoft Edge-TTS protocol. One instance per synthesis call; do
/// not reuse across calls.
final class EdgeTTSBridge: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    // MARK: - Constants (mirrors edge_tts/constants.py)

    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let wssBase =
        "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let chromiumMajor = "143"
    private static let secMSGECVersion = "1-143.0.3650.75"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" +
        " (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36" +
        " Edg/143.0.0.0"
    private static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    // MARK: - Public API

    /// Synthesizes `text` with the given voice and returns the MP3 bytes.
    /// Plain text; SSML envelope is built internally.
    func synthesize(
        text: String,
        voice: String,
        rate: String = "+0%",
        volume: String = "+0%",
        pitch: String = "+0Hz",
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let ssml = Self.makeSSML(text: text, voice: voice, rate: rate, volume: volume, pitch: pitch)
        return try await synthesize(ssml: ssml, timeout: timeout)
    }

    /// Synthesizes a pre-built SSML envelope.
    func synthesize(ssml: String, timeout: TimeInterval = 60) async throws -> Data {
        let connectionId = Self.uuidHex()
        let requestId = Self.uuidHex()
        let secMSGEC = Self.generateSecMSGEC()

        var components = URLComponents(string: Self.wssBase)!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: Self.trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionId),
            URLQueryItem(name: "Sec-MS-GEC", value: secMSGEC),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: Self.secMSGECVersion),
        ]
        guard let url = components.url else {
            throw EdgeTTSBridgeError.webSocketFailed("bad URL")
        }

        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
                         forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(Self.muidHex());", forHTTPHeaderField: "Cookie")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        let session = URLSession(configuration: configuration,
                                 delegate: self,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()

        // 1. speech.config
        let timestamp = Self.dateString()
        let configFrame =
            "X-Timestamp:\(timestamp)\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{" +
            "\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"" +
            "},\"outputFormat\":\"\(Self.outputFormat)\"}}}}\r\n"
        try await task.send(.string(configFrame))

        // 2. SSML
        let ssmlFrame =
            "X-RequestId:\(requestId)\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(timestamp)Z\r\n" +  // trailing Z — Microsoft bug, kept for compat
            "Path:ssml\r\n\r\n" +
            ssml
        try await task.send(.string(ssmlFrame))

        // 3. Drain
        var audio = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw EdgeTTSBridgeError.webSocketFailed("\(error)")
            }

            switch message {
            case .string(let text):
                if let pathLine = text.split(separator: "\r\n").first(where: {
                    $0.hasPrefix("Path:")
                }) {
                    let path = pathLine.dropFirst("Path:".count)
                    if path == "turn.end" {
                        task.cancel(with: .normalClosure, reason: nil)
                        guard !audio.isEmpty else {
                            throw EdgeTTSBridgeError.noAudioReceived
                        }
                        return audio
                    }
                    // turn.start / response / audio.metadata — ignore for one-shot
                }
            case .data(let data):
                // Binary frame layout: [2 bytes BE header length][headers][payload]
                guard data.count >= 2 else {
                    throw EdgeTTSBridgeError.invalidBinaryFrame
                }
                let headerLength = Int(data[0]) << 8 | Int(data[1])
                guard headerLength + 2 <= data.count else {
                    throw EdgeTTSBridgeError.invalidBinaryFrame
                }
                let payload = data.subdata(in: (2 + headerLength)..<data.count)
                if !payload.isEmpty {
                    audio.append(payload)
                }
            @unknown default:
                throw EdgeTTSBridgeError.unexpectedFrame("unknown message kind")
            }
        }
        throw EdgeTTSBridgeError.timeout
    }

    // MARK: - SSML

    static func makeSSML(text: String,
                         voice: String,
                         rate: String = "+0%",
                         volume: String = "+0%",
                         pitch: String = "+0Hz") -> String {
        let escaped = xmlEscape(text)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>" +
               "<voice name='\(voice)'>" +
               "<prosody pitch='\(pitch)' rate='\(rate)' volume='\(volume)'>" +
               "\(escaped)" +
               "</prosody></voice></speak>"
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Sec-MS-GEC token

    /// Matches edge_tts.drm.DRM.generate_sec_ms_gec — SHA-256 of
    /// (windows-filetime ticks rounded to 5min) || trustedClientToken,
    /// uppercased hex.
    static func generateSecMSGEC() -> String {
        let winEpoch: Double = 11_644_473_600
        var ticks = Date().timeIntervalSince1970 + winEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        let ticks100ns = ticks * 1e9 / 100
        let intTicks = UInt64(ticks100ns)
        let strToHash = "\(intTicks)\(trustedClientToken)"
        let hash = SHA256.hash(data: Data(strToHash.utf8))
        return hash.map { String(format: "%02X", $0) }.joined()
    }

    private static func uuidHex() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func muidHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // edge_tts uses strftime "%a %b %d %Y %H:%M:%S GMT+0000 (Coordinated Universal Time)"
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return formatter.string(from: Date()) + " GMT+0000 (Coordinated Universal Time)"
    }

    // MARK: - URLSessionWebSocketDelegate (silence default logs; no state needed)

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {}

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {}
}
