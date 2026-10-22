#if os(macOS)
import AppKit

@MainActor
final class MacBookConversionPresentation: NSObject {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    func chooseOptions() -> ConversionOptions? {
        let alert = NSAlert()
        alert.messageText = L10n.string("convert.title")
        alert.addButton(withTitle: L10n.string("convert.title"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 300, height: 28))
        choice.addItems(withTitles: [L10n.string("convert.usePreferences")] + AudioEnginePreference.supportedPreferences.map(\.displayName))
        choice.setAccessibilityLabel(L10n.string("settings.audioEngineChoice"))
        choice.setAccessibilityIdentifier("convert.tts.primary")
        choice.target = self
        choice.action = #selector(manualConversionEngineChanged(_:))
        let secondary = NSButton(checkboxWithTitle: L10n.string("convert.allowSecondary"), target: nil, action: nil)
        secondary.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        secondary.setAccessibilityIdentifier("convert.tts.useSecondary")
        secondary.state = settings.secondaryAudioEngine == nil ? .off : .on
        secondary.isEnabled = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        accessory.addSubview(choice)
        accessory.addSubview(secondary)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var options = settings.conversionOptions
        if choice.indexOfSelectedItem > 0 {
            let engine = AudioEnginePreference.supportedPreferences[choice.indexOfSelectedItem - 1]
            options = .selectedEngine(engine, modelsRoot: LocalSpeechModelReadiness.ttsModelsRoot())
            let distinctSecondary = settings.ttsPreferences.secondary.flatMap { $0 == .selected(engine) ? nil : $0 }
            options.ttsPreferences = TtsPreferences(primary: .selected(engine),
                secondary: secondary.state == .on ? distinctSecondary : nil,
                allowOnlineFallback: secondary.state == .on && distinctSecondary != nil && settings.allowOnlineAudioFallback,
                policyVersion: secondary.state == .on ? settings.ttsPreferences.policyVersion : nil)
            options.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
            options.espeakDataDirectory = Bundle.main.resourceURL?.path
        }
        return options
    }

    @objc private func manualConversionEngineChanged(_ sender: NSPopUpButton) {
        guard let secondary = sender.superview?.subviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == "convert.tts.useSecondary" }) else { return }
        let selected = sender.indexOfSelectedItem > 0
            ? TtsSelection.selected(AudioEnginePreference.supportedPreferences[sender.indexOfSelectedItem - 1]) : nil
        secondary.isEnabled = selected != nil && settings.ttsPreferences.secondary.map { $0 != selected } == true
        secondary.state = sender.indexOfSelectedItem == 0 && settings.secondaryAudioEngine != nil ? .on : .off
    }

}
#endif
