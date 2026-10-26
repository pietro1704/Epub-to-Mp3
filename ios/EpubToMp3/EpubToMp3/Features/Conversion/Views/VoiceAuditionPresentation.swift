#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class VoiceAuditionPresentation: NSObject {
    private let audition: VoiceAuditionController

    init(audition: VoiceAuditionController? = nil) {
        self.audition = audition ?? VoiceAuditionController()
        super.init()
    }
    #if os(macOS)
    private var sheet: NSAlert?
    func present(selection: TtsSelection, language: String, on window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        sheet = alert
        alert.messageText = L10n.string("voiceAudition.title")
        alert.informativeText = L10n.string("voiceAudition.preparing")
        alert.addButton(withTitle: L10n.string("voiceAudition.stop"))
        audition.onChange = { [weak alert] state in
            switch state {
            case .failed(let message): alert?.informativeText = message
            case .playing: alert?.informativeText = VoiceAuditionController.sample(language: language)
            case .idle: alert?.informativeText = L10n.string("voiceAudition.finished")
            case .generating: break
            }
        }
        alert.beginSheetModal(for: window) { [weak self] _ in self?.audition.stop(); self?.sheet = nil }
        audition.start(selection: selection, language: language)
    }
    #else
    func present(selection: TtsSelection, language: String, on controller: UIViewController) {
        let alert = UIAlertController(title: L10n.string("voiceAudition.title"),
            message: L10n.string("voiceAudition.preparing"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("voiceAudition.stop"), style: .cancel) { [weak self] _ in self?.audition.stop() })
        audition.onChange = { [weak alert] state in
            switch state {
            case .failed(let message): alert?.message = message
            case .playing: alert?.message = VoiceAuditionController.sample(language: language)
            case .idle: alert?.message = L10n.string("voiceAudition.finished")
            case .generating: break
            }
        }
        controller.present(alert, animated: true) { [weak self] in self?.audition.start(selection: selection, language: language) }
    }
    #endif
}
