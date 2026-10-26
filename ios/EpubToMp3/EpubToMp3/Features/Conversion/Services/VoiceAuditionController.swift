import Foundation
import AVFoundation

private struct VoiceAuditionInvocation: @unchecked Sendable {
    let adapter: ConverterFFIAdapter
    let control: ConverterPlaybackControl
    let options: ConversionOptions
    let text: String
    let output: URL
    func run() throws { try adapter.audition(text: text, options: options, output: output, control: control) }
}

/// An audition has its own audio player and cancellation identity. It never
/// changes AppSettings, ReaderProgressStore or the library's AudioPlayer.
@MainActor
final class VoiceAuditionController: NSObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, generating, playing, failed(String) }
    private(set) var state: State = .idle { didSet { onChange?(state) } }
    var onChange: ((State) -> Void)?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var control: ConverterPlaybackControl?
    private var player: AVAudioPlayer?
    private var directory: URL?
    private let renderer: (@MainActor (TtsSelection, String) async throws -> URL)?
    private let playback: ((URL) throws -> Bool)?
    private let modelsRoot: URL?

    init(modelsRoot: URL? = nil,
         renderer: (@MainActor (TtsSelection, String) async throws -> URL)? = nil,
         playback: ((URL) throws -> Bool)? = nil) {
        self.modelsRoot = modelsRoot
        self.renderer = renderer
        self.playback = playback
        super.init()
    }

    static func sample(language: String) -> String {
        switch language.prefix(2).lowercased() {
        case "pt": return "Esta é uma amostra da voz para narrar seus livros. Boa leitura!"
        case "es": return "Esta es una muestra de la voz para narrar tus libros. ¡Buena lectura!"
        default: return "This is a sample of the voice for narrating your books. Enjoy your reading!"
        }
    }

    @discardableResult
    func start(selection: TtsSelection, language: String) -> Task<Void, Never> {
        stop()
        let attempt = UUID()
        generation = attempt
        state = .generating
        task = Task { [weak self] in
            guard let self, generation == attempt, !Task.isCancelled else { return }
            do {
                if let renderer {
                    let output = try await renderer(selection, language)
                    guard generation == attempt, !Task.isCancelled else { return }
                    try play(output)
                    return
                }
                guard selection.engine == "piper", let modelID = selection.modelID,
                      let root = modelsRoot ?? LocalSpeechModelReadiness.ttsModelsRoot() else {
                    throw EmbeddedConverterError.artifactUnavailable
                }
                let adapter = ConverterFFIAdapter()
                let control = try adapter.makePlaybackControl()
                self.control = control
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-audition-\(attempt.uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                self.directory = directory
                var options = ConversionOptions(engine: "piper", language: language, modelsRoot: root.path,
                    modelID: modelID, espeakDataDirectory: Bundle.main.resourceURL?.path)
                options.ttsPreferences = TtsPreferences(primary: selection, secondary: nil, allowOnlineFallback: false)
                let output = directory.appendingPathComponent("preview.mp3")
                let invocation = VoiceAuditionInvocation(adapter: adapter, control: control, options: options,
                    text: Self.sample(language: language), output: output)
                do { try await Task.detached(priority: .userInitiated) { try invocation.run() }.value }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                guard generation == attempt, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                try play(output)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                // Rendering has returned here; a decoder/startup failure still
                // owns a completed temporary artifact that must be removed.
                if let directory { try? FileManager.default.removeItem(at: directory) }
                stop()
                state = .failed(error.localizedDescription)
            }
        }
        return task!
    }

    private func play(_ output: URL) throws {
        let started: Bool
        if let playback { started = try playback(output) }
        else {
            let player = try AVAudioPlayer(contentsOf: output)
            player.delegate = self
            self.player = player
            started = player.play()
        }
        guard started else { throw EmbeddedConverterError.conversionFailed("Audition audio could not start") }
        state = .playing
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        control?.cancel()
        control = nil
        player?.stop()
        player = nil
        // A running synthesis cleans its own temporary directory after returning.
        if state != .generating, let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        state = .idle
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            stop()
            if !flag { state = .failed(L10n.string("voiceAudition.failed")) }
        }
    }
}
