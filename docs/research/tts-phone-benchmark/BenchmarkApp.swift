import UIKit
import AVFoundation
import Darwin

private func benchmarkClock() -> Double { ProcessInfo.processInfo.systemUptime }
private func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}
private final class Progress {
    var started = benchmarkClock()
    var first: Double?
}

@main
final class BenchmarkApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let label = UILabel()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.text = "Isolated TTS benchmark\nNo audible playback"
        label.frame = CGRect(x: 24, y: 100, width: 320, height: 500)
        controller.view.addSubview(label)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
        Task.detached { await self.run() }
        return true
    }
    func run() async {
        let engine = UserDefaults.standard.string(forKey: "engine") ?? "edge"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("results/\(engine)")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = ["engine": engine, "hardware": "iPhone 16e", "os": ProcessInfo.processInfo.operatingSystemVersionString, "runtime": "sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2 CPU", "threads": 2, "runs": [], "scope": "Isolated model harness; not production conversion pipeline", "peak_rss_scope": "process lifetime including framework load and audio validation; fresh process per engine", "audible_playback": false]
        var rows = [[String: Any]]()
        func checkpoint() {
            report["runs"] = rows
            report["peak_rss_bytes"] = peakRSS()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        checkpoint()
        do {
            #if !POCKET_RUNTIME
            if engine == "pocket" { throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pocket Portuguese native adapter is not linked in this build."]) }
            #endif
            let corpus = [
                ("short", "A biblioteca estava silenciosa. \"Vamos começar?\", perguntou Ana. Às 8h30, ela abriu o livro e leu a primeira página."),
                ("paragraph", "Na manhã de terça-feira, Ana encontrou um livro antigo na biblioteca. A capa estava gasta, mas as páginas permaneciam legíveis. \"Quanto custa?\", perguntou ela. O funcionário respondeu: \"Vinte e três reais e cinquenta centavos.\" Ana sorriu, conferiu o relógio às 8h30 e decidiu começar a leitura. No primeiro capítulo, um viajante atravessava a cidade em busca de notícias de sua família. Ele parou diante da estação, observou as pessoas e perguntou qual trem partiria às 14h15. A resposta chegou depressa: plataforma número 3. Mesmo com a chuva e o vento, o viajante continuou seu caminho. Não precisava correr; precisava apenas chegar antes do anoitecer.")
            ]
            let loadStart = benchmarkClock()
            var tts: SherpaOnnxOfflineTtsWrapper?
            #if POCKET_RUNTIME
            var pocket: UnsafeMutableRawPointer?
            defer { if let pocket { ptt_destroy(pocket) } }
            #endif
            var generation = SherpaOnnxGenerationConfigSwift()
            #if POCKET_RUNTIME
            if engine == "pocket" {
                let path = documents.appendingPathComponent("models/pocket-portuguese").path
                pocket = ptt_create(path, path, path + "/tokenizer.model", "int8", 0.7, 1, 2)
                guard pocket != nil else { throw NSError(domain: "Benchmark", code: 10, userInfo: [NSLocalizedDescriptionKey: "Pocket native creation failed"]) }
                report["runtime"] = "PocketTTS.cpp-multilingual / ONNX Runtime 1.28.2 CPU; 2 total threads"
                report["voice"] = "Synthetic Edge short fixture reference.wav; voice-conditioned Portuguese, not a stock Pocket voice"
                report["cache"] = "Fresh engine process; warm iterations retain voice conditioning KV state"
            }
            #endif
            if engine != "edge" && engine != "pocket" {
                let name: String
                switch engine {
                case "edresson": name = "vits-piper-pt_BR-edresson-low"
                case "faber": name = "vits-piper-pt_BR-faber-medium"
                case "kokoro": name = "kokoro-int8-multi-lang-v1_0"
                default: name = "sherpa-onnx-supertonic-3-tts-int8-2026-05-11"
                }
                let root = documents.appendingPathComponent("models/\(name)").path
                func path(_ file: String) -> String { root + "/" + file }
                let model: SherpaOnnxOfflineTtsModelConfig
                if engine == "edresson" || engine == "faber" {
                    let files = try FileManager.default.contentsOfDirectory(atPath: root)
                    guard let onnx = files.first(where: { $0.hasSuffix(".onnx") }) else { throw NSError(domain: "Benchmark", code: 2) }
                    model = sherpaOnnxOfflineTtsModelConfig(vits: sherpaOnnxOfflineTtsVitsModelConfig(model: path(onnx), tokens: path("tokens.txt"), dataDir: path("espeak-ng-data")), numThreads: 2)
                } else if engine == "kokoro" {
                    model = sherpaOnnxOfflineTtsModelConfig(kokoro: sherpaOnnxOfflineTtsKokoroModelConfig(model: path("model.int8.onnx"), voices: path("voices.bin"), tokens: path("tokens.txt"), dataDir: path("espeak-ng-data"), lang: "pt-br"), numThreads: 2)
                    generation.sid = 42
                    report["voice"] = "pf_dora, sid=42, official v1_0 speaker map"
                } else {
                    model = sherpaOnnxOfflineTtsModelConfig(numThreads: 2, supertonic: sherpaOnnxOfflineTtsSupertonicModelConfig(durationPredictor: path("duration_predictor.int8.onnx"), textEncoder: path("text_encoder.int8.onnx"), vectorEstimator: path("vector_estimator.int8.onnx"), vocoder: path("vocoder.int8.onnx"), ttsJson: path("tts.json"), unicodeIndexer: path("unicode_indexer.bin"), voiceStyle: path("voice.bin")))
                    generation.sid = 0
                    generation.numSteps = 8
                    generation.extra = ["lang": "pt"]
                    report["voice"] = "preset sid=0, 8 steps"
                }
                var config = sherpaOnnxOfflineTtsConfig(model: model)
                tts = SherpaOnnxOfflineTtsWrapper(config: &config)
                guard tts?.tts != nil else { throw NSError(domain: "Benchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native model creation failed"]) }
            } else if engine == "edge" {
                #if RUST_EDGE
                report["runtime"] = "Production converter-core Rust reference Edge client through isolated C entrypoint"
                #else
                report["runtime"] = "Existing repository Swift EdgeTTSBridge; network baseline, not Rust production pipeline"
                #endif
                report["voice"] = "pt-BR-FranciscaNeural"
            }
            report["load_seconds"] = benchmarkClock() - loadStart
            checkpoint()
            for (name, text) in corpus {
                for iteration in 1...3 {
                    await MainActor.run { self.label.text = "Isolated TTS benchmark\n\(engine) / \(name) / \(iteration)\nNo audible playback" }
                    let started = benchmarkClock()
                    let file = output.appendingPathComponent("\(name)-\(iteration).\(engine == "edge" ? "mp3" : "wav")")
                    let progress = Progress()
                    progress.started = started
                    var row: [String: Any] = ["corpus": name, "text": text, "characters": text.count, "iteration": iteration, "model_state": name == "short" && iteration == 1 ? "first_generation_after_load" : "warm_model", "file": file.lastPathComponent]
                    if let tts {
                        let callback: TtsProgressCallbackWithArg = { _, count, _, raw in
                            let state = Unmanaged<Progress>.fromOpaque(raw!).takeUnretainedValue()
                            if count > 0 && state.first == nil { state.first = benchmarkClock() - state.started }
                            return 1
                        }
                        let audio = tts.generateWithConfig(text: text, config: generation, callback: callback, arg: Unmanaged.passUnretained(progress).toOpaque())
                        guard audio.audio != nil, audio.n > 0 else { throw NSError(domain: "Benchmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "No generated samples"]) }
                        row["synthesis_seconds"] = benchmarkClock() - started
                        row["first_pcm_callback_seconds"] = progress.first ?? NSNull()
                        guard audio.save(filename: file.path) == 1 else { throw NSError(domain: "Benchmark", code: 5) }
                    }
                    #if POCKET_RUNTIME
                    if let pocket {
                        let voice = documents.appendingPathComponent("models/pocket-portuguese/reference.wav").path
                        guard let stream = ptt_stream_start(pocket, text, voice) else { throw NSError(domain: "Benchmark", code: 11) }
                        defer { ptt_stream_end(stream) }
                        var samples = [Float]()
                        while true {
                            var pointer: UnsafeMutablePointer<Float>?
                            var count: Int32 = 0
                            let status = ptt_stream_read(stream, &pointer, &count)
                            if status == 0 { break }
                            guard status == 1, count > 0, let pointer else { throw NSError(domain: "Benchmark", code: 12) }
                            if progress.first == nil { progress.first = benchmarkClock() - started }
                            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(count)))
                            ptt_free_audio(pointer)
                        }
                        guard !samples.isEmpty else { throw NSError(domain: "Benchmark", code: 13, userInfo: [NSLocalizedDescriptionKey: "Pocket generated no samples; inspect console log"]) }
                        row["synthesis_seconds"] = benchmarkClock() - started
                        row["first_pcm_callback_seconds"] = progress.first ?? NSNull()
                        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                        buffer.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { values in buffer.floatChannelData![0].update(from: values.baseAddress!, count: samples.count) }
                        let writer = try AVAudioFile(forWriting: file, settings: format.settings)
                        try writer.write(from: buffer)
                    }
                    #endif
                    if engine == "edge" {
                        #if RUST_EDGE
                        var error = [CChar](repeating: 0, count: 1024)
                        let status = benchmark_edge(text, file.path, &error, Int32(error.count))
                        guard status == 0 else { throw NSError(domain: "Benchmark", code: 14, userInfo: [NSLocalizedDescriptionKey: String(cString: error)]) }
                        row["synthesis_seconds"] = benchmarkClock() - started
                        row["first_pcm_callback_seconds"] = NSNull()
                        #else
                        let audio = try await EdgeTTSBridge().synthesize(text: text, voice: "pt-BR-FranciscaNeural", timeout: 45)
                        row["synthesis_seconds"] = benchmarkClock() - started
                        row["first_pcm_callback_seconds"] = NSNull()
                        try audio.write(to: file)
                        #endif
                    }
                    row["file_ready_seconds"] = benchmarkClock() - started
                    let audio = try AVAudioFile(forReading: file)
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    guard duration > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { throw NSError(domain: "Benchmark", code: 6) }
                    var peak: Float = 0
                    var decoded: Int64 = 0
                    while audio.framePosition < audio.length {
                        try audio.read(into: buffer)
                        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw NSError(domain: "Benchmark", code: 7) }
                        for channel in 0..<Int(buffer.format.channelCount) {
                            for index in 0..<Int(buffer.frameLength) {
                                let value = channels[channel][index]
                                guard value.isFinite else { throw NSError(domain: "Benchmark", code: 8) }
                                peak = max(peak, abs(value))
                            }
                        }
                        decoded += Int64(buffer.frameLength)
                    }
                    guard peak > 0.001, decoded > 0 else { throw NSError(domain: "Benchmark", code: 9, userInfo: [NSLocalizedDescriptionKey: "Silent or undecodable audio"]) }
                    row["audio_duration_seconds"] = duration
                    row["sample_rate"] = audio.processingFormat.sampleRate
                    row["peak_amplitude"] = peak
                    row["decoded_frames"] = decoded
                    row["rtf_file_ready"] = (row["file_ready_seconds"] as! Double) / duration
                    row["validation_seconds"] = benchmarkClock() - started - (row["file_ready_seconds"] as! Double)
                    row["peak_rss_bytes"] = peakRSS()
                    row["status"] = "passed_full_decode"
                    rows.append(row)
                    checkpoint()
                }
            }
            report["status"] = "passed"
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
        }
        checkpoint()
        await MainActor.run { self.label.text = "Benchmark \(engine): \(report["status"]!)\n\(report["error"] ?? "Report saved")" }
        print("TTS_BENCHMARK_COMPLETE \(engine) \(report["status"]!)")
        fflush(stdout)
        exit(0)
    }
}
