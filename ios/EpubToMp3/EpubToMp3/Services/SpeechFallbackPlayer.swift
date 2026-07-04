import Foundation
import AVFoundation

// MARK: - Testable seams
//
// `AVSpeechSynthesizer` and `AVAudioSession` are global, statefully
// shared system singletons. To keep the player unit-testable on the
// macOS host (where there is no AVAudioSession at all) and on CI
// (where we must never actually speak or take over the user's audio
// session), every interaction with those subsystems goes through a
// protocol that is also implemented by the real Apple types.

/// Subset of `AVSpeechSynthesizer` that `SpeechFallbackPlayer` relies
/// on. The real `AVSpeechSynthesizer` is conformed below via an
/// empty extension; tests inject a recording fake.
protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

/// Single method the player calls on the system audio session right
/// before speaking. Kept narrow on purpose so tests don't have to
/// stand up `AVAudioSession` mocks. `throws` because the iOS impl
/// can — the macOS impl is a no-op.
protocol SpeechAudioSessionConfiguring {
    func configureForSpeech() throws
}

/// Real iOS implementation. Mirrors `AudioPlayer.ensureAudioSession()`'s
/// category/mode/options so the synthesized speech route lines up with
/// the MP3 playback route — no audio dropouts when the fallback kicks
/// in mid-listening session. Deliberately does NOT call
/// `setActive(true)`: per the project convention codified in
/// `AudioPlayer.swift`, session activation belongs to whoever owns
/// playback, and the speech fallback piggybacks on whatever the
/// `AudioPlayer` has already activated.
struct SystemSpeechAudioSession: SpeechAudioSessionConfiguring {
    func configureForSpeech() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.allowBluetoothA2DP, .allowAirPlay]
        )
        #endif
    }
}

// MARK: - Player

/// Accessibility-grade speech fallback for chapters whose generated
/// MP3 is not ready or not playable. Wraps `AVSpeechSynthesizer` with
/// a small idle / speaking / paused state machine that mirrors the
/// `AudioPlayer` transport surface so the UI can treat them
/// interchangeably.
///
/// This service is intentionally NOT wired into `AudioPlayer` yet —
/// the first slice ships the engine in isolation with full unit-test
/// coverage; wiring lands in a follow-up.
@MainActor
final class SpeechFallbackPlayer: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case speaking
        case paused
    }

    @Published private(set) var state: State = .idle

    // Deferred to first use: AVSpeechSynthesizer init loads the TTS
    // system library and blocks the MainActor for 200-800 ms if done
    // at app launch. Injected via factory so tests can provide a fake
    // without triggering the real load.
    private var _synthesizer: SpeechSynthesizing?
    private let synthesizerFactory: () -> SpeechSynthesizing
    private var synthesizer: SpeechSynthesizing {
        if let s = _synthesizer { return s }
        let s = synthesizerFactory()
        s.delegate = self
        _synthesizer = s
        return s
    }
    private let sessionConfigurator: SpeechAudioSessionConfiguring

    init(
        synthesizer: SpeechSynthesizing? = nil,
        sessionConfigurator: SpeechAudioSessionConfiguring = SystemSpeechAudioSession()
    ) {
        // When a concrete instance is injected (tests / previews), wrap
        // it in a factory that returns it directly.  When nil, defer
        // creation of the real AVSpeechSynthesizer to first use.
        if let synthesizer {
            self.synthesizerFactory = { synthesizer }
            self._synthesizer = synthesizer
        } else {
            self.synthesizerFactory = { AVSpeechSynthesizer() }
            self._synthesizer = nil
        }
        self.sessionConfigurator = sessionConfigurator
        super.init()
        // Delegate is wired lazily inside the `synthesizer` accessor.
    }

    // MARK: Transport API

    /// Speak `text` aloud using the best-matching voice for
    /// `languageCode` (BCP-47, e.g. "pt-BR"). Empty text is a no-op.
    /// Unknown language tags fall back to the system default voice.
    func speak(text: String, languageCode: String? = nil) {
        guard !text.isEmpty else { return }
        try? sessionConfigurator.configureForSpeech()
        let utterance = AVSpeechUtterance(string: text)
        if let code = languageCode, let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        // No `else` voice assignment — leaving voice nil lets
        // AVSpeechSynthesizer pick the system default for the user's
        // locale, which is the safe fallback behaviour.
        synthesizer.speak(utterance)
        state = .speaking
    }

    func pause() {
        guard state == .speaking else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .speaking
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechFallbackPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.state = .idle
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.state = .idle
        }
    }
}
