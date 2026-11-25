#if os(iOS)
import UIKit

@MainActor
enum ReaderVoicePickerPresentation {
    static func present(from reader: UIViewController, anchor: UIBarButtonItem?, request: ReaderVoicePickerRequest) {
        guard reader.presentedViewController == nil else { return }
        Task { @MainActor [weak reader, weak anchor] in
            guard let picker = request.picker() else { return }
            // Only the book's language, only what is ready. The menu opens at once: with the book's models
            // already listed that is immediate; otherwise it opens with the active voice and fills in when ready.
            let work = Task { @MainActor in await ReaderModelSwitch.content(picker: picker, request: request) }
            let ready = await ReaderModelSwitch.firstResult(of: work, within: 0.12)
            guard let reader, reader.viewIfLoaded?.window != nil, reader.presentedViewController == nil else { return }
            @MainActor func alert(_ content: ReaderModelSwitch.Content?) -> UIAlertController {
                let alert = makeAlert(picker: picker, content: content, catalog: SpeechModelLibraryViewState(snapshot: nil),
                                      settings: request.settings) { [weak reader] in
                    guard let reader, reader.viewIfLoaded?.window != nil, request.currentContext() != nil else { return }
                    presentModels(on: reader, request: request, language: content?.language)
                }
                alert.popoverPresentationController?.barButtonItem = anchor
                alert.popoverPresentationController?.sourceView = reader.view
                alert.popoverPresentationController?.sourceRect = CGRect(
                    x: reader.view.bounds.midX, y: reader.view.bounds.minY, width: 1, height: 1)
                return alert
            }
            if let ready {
                reader.present(alert(ready), animated: true)
                return
            }
            let placeholder = alert(nil)
            reader.present(placeholder, animated: true)
            guard let full = await work.value else { return }
            // The listing arrived while the menu is still up: replace it with the complete one.
            guard reader.presentedViewController === placeholder else { return }
            placeholder.dismiss(animated: false) { [weak reader] in
                guard let reader, reader.viewIfLoaded?.window != nil, reader.presentedViewController == nil else { return }
                reader.present(alert(full), animated: false)
            }
        }
    }

    /// The Models screen, on the book's language, above the reader.
    private static func presentModels(on reader: UIViewController, request: ReaderVoicePickerRequest, language: String?) {
        let controller = ModelsScreenController(settings: request.settings, focusLanguage: language)
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier = "reader.models.done"
        reader.present(navigation, animated: true)
    }

    private static func makeAlert(picker: ReaderVoicePicker, content: ReaderModelSwitch.Content?,
                                  catalog: SpeechModelLibraryViewState, settings: AppSettings,
                                  downloads: @escaping () -> Void) -> UIAlertController {
        let message = content?.hasNoModel == true
            ? L10n.string("models.missing.message", content?.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } ?? "")
            : nil
        let alert = UIAlertController(title: L10n.string("models.title"), message: message, preferredStyle: .actionSheet)
        alert.view.accessibilityIdentifier = "reader.voicePicker"
        for choice in content?.choices
                ?? picker.choices(from: catalog, allowOnlineFallback: settings.allowOnlineAudioFallback) {
            let title = choice.selected ? "✓ \(choice.title)" : choice.title
            let action = UIAlertAction(title: title, style: .default) { _ in
                if let content { content.choose(choice.selection, picker: picker, settings: settings) }
                else { picker.choose(choice.selection) }
            }
            action.isEnabled = choice.available
            alert.addAction(action)
        }
        if let useDefault = picker.useDefault {
            let title = ReaderModelSwitch.Content.useDefaultTitle(language: content?.language)
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in Task { await useDefault() } })
        }
        alert.addAction(UIAlertAction(title: L10n.string("models.missing.open"), style: .default) { [weak alert] _ in
            alert?.dismiss(animated: true, completion: downloads)
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        return alert
    }
}
#elseif os(macOS)
import AppKit

@MainActor
final class MacReaderVoicePickerPresenter {
    private var isOpening = false

    func present(from reader: NSViewController, anchor: NSView, request: ReaderVoicePickerRequest) {
        guard !isOpening, reader.presentedViewControllers?.isEmpty != false else { return }
        isOpening = true
        Task { [weak self, weak reader, weak anchor] in
            guard let self else { return }
            defer { self.isOpening = false }
            guard let picker = request.picker() else { return }
            // Only the book's language, only what is ready; the study-language catalog is the fallback. A popup
            // menu cannot update once it is up, so it waits for the listing, which is cached per book (and
            // scanned off the main thread) after the first opening.
            let content = await ReaderModelSwitch.content(picker: picker, request: request)
            let snapshot = content == nil ? try? await SpeechModelLibraryClient.shared.snapshot() : nil
            guard let reader, let anchor, anchor.window != nil, reader.presentedViewControllers?.isEmpty != false else { return }
            let presentation = ReaderVoicePickerPresentation(picker: picker, content: content, settings: request.settings,
                catalog: SpeechModelLibraryViewState(snapshot: snapshot)) { [weak reader] in
                Task { @MainActor in
                    guard let reader, reader.view.window != nil, request.currentContext() != nil else { return }
                    Self.presentModels(on: reader, request: request, language: content?.language)
                }
            }
            withExtendedLifetime(presentation) {
                _ = presentation.menu.popUp(positioning: nil,
                    at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), in: anchor)
            }
        }
    }

    /// The Models screen, on the book's language, as a sheet over the reader.
    private static func presentModels(on reader: NSViewController, request: ReaderVoicePickerRequest, language: String?) {
        let models = MacModelsViewController(settings: request.settings, focusLanguage: language)
        var sheet: NSViewController?
        let container = MacSettingsDetailNavigation(detail: models) { [weak reader] in
            if let sheet { reader?.dismiss(sheet) }
        }
        sheet = container
        container.preferredContentSize = NSSize(width: 760, height: 620)
        reader.presentAsSheet(container)
    }
}

/// Holds AppKit menu targets alive while tracking a reader voice choice.
@MainActor
private final class ReaderVoicePickerPresentation: NSObject {
    let menu = NSMenu(title: L10n.string("models.title"))
    private let choices: [ReaderVoicePicker.Choice]
    private let picker: ReaderVoicePicker
    private let downloads: () -> Void

    private let content: ReaderModelSwitch.Content?
    private let settings: AppSettings

    init(picker: ReaderVoicePicker, content: ReaderModelSwitch.Content?, settings: AppSettings,
         catalog: SpeechModelLibraryViewState, downloads: @escaping () -> Void) {
        self.picker = picker
        self.content = content
        self.settings = settings
        self.choices = content?.choices
            ?? picker.choices(from: catalog, allowOnlineFallback: settings.allowOnlineAudioFallback)
        self.downloads = downloads
        super.init()
        menu.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = choice.selected ? .on : .off
            item.isEnabled = choice.available
            menu.addItem(item)
        }
        if content?.hasNoModel == true {
            let note = NSMenuItem(title: L10n.string("models.missing.title"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        if picker.useDefault != nil {
            let reset = NSMenuItem(title: ReaderModelSwitch.Content.useDefaultTitle(language: content?.language),
                                   action: #selector(useDefaultVoice), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        let item = NSMenuItem(title: L10n.string("models.missing.open"), action: #selector(showDownloads), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard choices.indices.contains(item.tag), choices[item.tag].available else { return }
        if let content { content.choose(choices[item.tag].selection, picker: picker, settings: settings) }
        else { picker.choose(choices[item.tag].selection) }
    }

    @objc private func useDefaultVoice() {
        guard let useDefault = picker.useDefault else { return }
        Task { await useDefault() }
    }

    @objc private func showDownloads() { downloads() }
}
#endif
