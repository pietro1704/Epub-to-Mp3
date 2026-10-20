import AVFoundation
import Foundation

/// Pure selection over installed voices; never resolves an identifier that could
/// trigger a voice download. A segment retains the selected voice object.
enum InstalledSpeechVoicePolicy {
    struct Voice: Equatable, Sendable {
        let identifier: String
        let name: String
        let language: String
        let isCompact: Bool
    }

    static func select(language: String, voices: [Voice]) -> String? {
        let locale = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let regionSpecified = locale.contains("-")
        let preferredLocale = ["pt": "pt-br", "en": "en-us", "es": "es-es"][locale]
        let compatible = voices.filter {
            let voiceLocale = $0.language.replacingOccurrences(of: "_", with: "-").lowercased()
            return regionSpecified ? voiceLocale == locale
                : voiceLocale.split(separator: "-").first.map(String.init) == locale
        }
        func rank(_ voice: Voice) -> Int {
            let voiceLocale = voice.language.replacingOccurrences(of: "_", with: "-").lowercased()
            if (locale == "pt" || locale == "pt-br"), voiceLocale == "pt-br",
               voice.name.caseInsensitiveCompare("Luciana") == .orderedSame {
                return 0
            }
            return (voiceLocale == preferredLocale ? 1 : 3) + (voice.isCompact ? 0 : 1)
        }
        return compatible.sorted {
            let lhs = rank($0), rhs = rank($1)
            return lhs == rhs ? $0.identifier < $1.identifier : lhs < rhs
        }.first?.identifier
    }
}

/// Apple supplies PCM only; Rust owns provider policy, encoding, and artifacts.
final class PlatformSpeechSynthesizer: @unchecked Sendable {
    private let requestLock: NSLock
    private let onVoiceUsed: @Sendable (InstalledSpeechVoicePolicy.Voice) -> Void

    init(requestLock: NSLock = NSLock(),
         onVoiceUsed: @escaping @Sendable (InstalledSpeechVoicePolicy.Voice) -> Void = { _ in }) {
        self.requestLock = requestLock
        self.onVoiceUsed = onVoiceUsed
    }

    func synthesizeWAV(text: String, language: String, output: URL,
                       cancelled: () -> Bool, timeout: TimeInterval = 90) throws {
        guard !Thread.isMainThread else { throw Failure("System speech cannot block the main thread.") }
        guard timeout > 0 else { throw Failure("System speech timed out.") }
        let queueDeadline = Date().addingTimeInterval(min(timeout, 30))
        while !requestLock.try() {
            guard !cancelled() else { throw Failure("System speech cancelled while queued.") }
            guard Date() < queueDeadline else { throw Failure("System speech queue timed out.") }
            Thread.sleep(forTimeInterval: 0.025)
        }
        defer { requestLock.unlock() }
        guard !cancelled() else { throw Failure("System speech cancelled.") }
        let request = Request()
        DispatchQueue.main.async { request.start(text: text, language: language) }
        let deadline = Date().addingTimeInterval(timeout)
        while request.done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() { request.finish(error: Failure("System speech cancelled.")); break }
            if Date() >= deadline { request.finish(error: Failure("System speech timed out.")); break }
        }
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { request.stop(); stopped.signal() }
        guard stopped.wait(timeout: .now() + 5) == .success else {
            throw Failure("System speech cleanup timed out.")
        }
        if cancelled() { throw Failure("System speech cancelled.") }
        let wav = try request.wav()
        try wav.write(to: output, options: .atomic)
        if let voice = request.usedVoice() { onVoiceUsed(voice) }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class Request: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false
        private var failure: Error?
        private var samples = Data()
        private var sampleRate: UInt32 = 0
        private var synthesizer: AVSpeechSynthesizer?
        private var selectedVoice: InstalledSpeechVoicePolicy.Voice?

        func usedVoice() -> InstalledSpeechVoicePolicy.Voice? {
            lock.lock(); defer { lock.unlock() }
            return selectedVoice
        }

        func start(text: String, language: String) {
            lock.lock(); let alreadyFinished = finished; lock.unlock()
            guard !alreadyFinished else { return }
            let locale = language.replacingOccurrences(of: "_", with: "-")
            let voices = AVSpeechSynthesisVoice.speechVoices()
            let selected = InstalledSpeechVoicePolicy.select(language: locale, voices: voices.map {
                .init(identifier: $0.identifier, name: $0.name, language: $0.language,
                      isCompact: $0.quality == .default)
            })
            guard let voice = voices.first(where: { $0.identifier == selected }) else {
                finish(error: Failure("No installed system voice for \(locale).")); return
            }
            lock.lock()
            selectedVoice = .init(identifier: voice.identifier, name: voice.name, language: voice.language,
                                  isCompact: voice.quality == .default)
            lock.unlock()
            let synth = AVSpeechSynthesizer()
            synthesizer = synth
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synth.write(utterance) { [self] buffer in consume(buffer) }
        }

        func stop() {
            synthesizer?.stopSpeaking(at: .immediate)
            synthesizer = nil
        }

        func finish(error: Error? = nil) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            failure = error
            lock.unlock()
            done.signal()
        }

        private func consume(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finish(error: Failure("System speech returned a non-PCM buffer.")); return
            }
            guard pcm.frameLength > 0 else { finish(); return }
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            guard pcm.format.sampleRate.isFinite, pcm.format.sampleRate > 0,
                  pcm.format.sampleRate <= 192_000 else {
                lock.unlock()
                finish(error: Failure("System speech returned an invalid sample rate."))
                lock.lock()
                return
            }
            let rate = UInt32(pcm.format.sampleRate)
            guard sampleRate == 0 || sampleRate == rate,
                  pcm.format.channelCount > 0,
                  pcm.floatChannelData != nil || pcm.int16ChannelData != nil || pcm.int32ChannelData != nil,
                  samples.count + Int(pcm.frameLength) * 2 <= 128 * 1024 * 1024 else {
                lock.unlock()
                finish(error: Failure("System speech returned unsupported or excessive PCM."))
                lock.lock()
                return
            }
            sampleRate = rate
            let channels = Int(pcm.format.channelCount)
            var chunk = Data(count: Int(pcm.frameLength) * 2)
            chunk.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                let output = bytes.bindMemory(to: Int16.self)
                for frame in 0..<Int(pcm.frameLength) {
                    var value: Double = 0
                    for channel in 0..<channels {
                        let plane = pcm.format.isInterleaved ? 0 : channel
                        let index = pcm.format.isInterleaved ? frame * channels + channel : frame
                        if let floats = pcm.floatChannelData { value += Double(floats[plane][index]) }
                        else if let ints = pcm.int16ChannelData { value += Double(ints[plane][index]) / 32768 }
                        else if let ints = pcm.int32ChannelData { value += Double(ints[plane][index]) / 2147483648 }
                    }
                    value /= Double(channels)
                    output[frame] = Int16(max(-32768, min(32767, value.isFinite ? value * 32768 : 0))).littleEndian
                }
            }
            samples.append(chunk)
        }

        func wav() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            if let failure { throw failure }
            guard !samples.isEmpty, sampleRate > 0 else { throw Failure("System speech produced no audio.") }
            var result = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
            }
            append(UInt32(36 + samples.count)); result.append(Data("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
            append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
            result.append(Data("data".utf8)); append(UInt32(samples.count)); result.append(samples)
            return result
        }
    }
}

/// One conversion owns one receipt; successful PCM production is the only source of voice identity.
final class PlatformSpeechVoiceReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var latestVoice: InstalledSpeechVoicePolicy.Voice?
    private var usedVoices: [String: InstalledSpeechVoicePolicy.Voice] = [:]
    private var providers: [Int: [String: Any]] = [:]

    func record(_ voice: InstalledSpeechVoicePolicy.Voice) {
        lock.lock(); defer { lock.unlock() }
        latestVoice = voice
        usedVoices[voice.identifier] = voice
    }

    func progress(_ data: Data) -> Data {
        guard var fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        lock.lock(); defer { lock.unlock() }
        if let chapter = fields["chapterIndex"] as? Int {
            var provider = providers[chapter] ?? [:]
            if let engine = fields["engine"] as? String, engine != provider["engine"] as? String {
                provider.removeAll()
            }
            for key in ["engine", "modelId", "voice"] {
                if let value = fields[key] { provider[key] = value }
            }
            providers[chapter] = provider
        }
        if fields["engine"] as? String == "system", let voice = latestVoice {
            fields["voice"] = voice.name + " (" + voice.identifier + ")"
            fields["modelId"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? data
    }

    func chapter(_ data: Data) -> Data {
        guard var fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        lock.lock(); defer { lock.unlock() }
        guard let chapter = fields["chapterIndex"] as? Int, let provider = providers[chapter] else { return data }
        for key in ["engine", "modelId", "voice"] {
            if let value = provider[key] { fields[key] = value }
        }
        if provider["engine"] as? String == "system", let voice = latestVoice {
            fields["voice"] = voice.name + " (" + voice.identifier + ")"
            fields["modelId"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? data
    }

    func manifest(_ data: Data) -> Data {
        guard var envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var manifest = envelope["manifest"] as? [String: Any],
              var selections = manifest["usedSelections"] as? [[String: Any]] else { return data }
        lock.lock()
        let voices = usedVoices.values.sorted { $0.identifier < $1.identifier }
        lock.unlock()
        guard !voices.isEmpty else { return data }
        for index in selections.indices where selections[index]["engine"] as? String == "system" {
            selections[index]["voice"] = voices.map { $0.name + " (" + $0.identifier + ")" }.joined(separator: " + ")
        }
        manifest["usedSelections"] = selections
        envelope["manifest"] = manifest
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? data
    }
}
