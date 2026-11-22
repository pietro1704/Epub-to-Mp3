#if os(iOS)
import UIKit

@MainActor
enum ReaderVoicePickerPresentation {
    static func present(from reader: UIViewController, anchor: UIBarButtonItem?, request: ReaderVoicePickerRequest) {
        guard reader.presentedViewController == nil else { return }
        Task { [weak reader, weak anchor] in
            let snapshot = try? await SpeechModelLibraryClient.shared.snapshot()
            guard let reader, reader.viewIfLoaded?.window != nil, reader.presentedViewController == nil,
                  let picker = request.picker() else { return }
            let alert = makeAlert(picker: picker, catalog: SpeechModelLibraryViewState(snapshot: snapshot)) { [weak reader] in
                guard let reader, reader.viewIfLoaded?.window != nil, request.currentContext() != nil else { return }
                presentDownloads(on: reader, request: request, picker: picker)
            }
            alert.popoverPresentationController?.barButtonItem = anchor
            alert.popoverPresentationController?.sourceView = reader.view
            alert.popoverPresentationController?.sourceRect = CGRect(
                x: reader.view.bounds.midX, y: reader.view.bounds.minY, width: 1, height: 1)
            reader.present(alert, animated: true)
        }
    }

    private static func presentDownloads(on reader: UIViewController,
                                         request: ReaderVoicePickerRequest, picker: ReaderVoicePicker) {
        let controller = SettingsScreenController(settings: request.settings, library: request.library,
            player: request.player, playbackClock: request.player.playbackClock,
            voiceModelsOnly: true, readerVoicePicker: picker)
        let navigation = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .cancel,
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        reader.present(navigation, animated: true)
    }

    private static func makeAlert(picker: ReaderVoicePicker, catalog: SpeechModelLibraryViewState,
                          downloads: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(title: L10n.string("settings.voiceModels"), message: nil, preferredStyle: .actionSheet)
        alert.view.accessibilityIdentifier = "reader.voicePicker"
        for choice in picker.choices(from: catalog) {
            let title = choice.selected ? "✓ \(choice.title)" : choice.title
            let action = UIAlertAction(title: title, style: .default) { _ in picker.choose(choice.selection) }
            action.isEnabled = choice.available
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: L10n.string("settings.voiceModelDownloads"), style: .default) { [weak alert] _ in
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
            let snapshot = try? await SpeechModelLibraryClient.shared.snapshot()
            guard let self else { return }
            defer { self.isOpening = false }
            guard let reader, let anchor, anchor.window != nil, reader.presentedViewControllers?.isEmpty != false,
                  let picker = request.picker() else { return }
            let presentation = ReaderVoicePickerPresentation(picker: picker,
                catalog: SpeechModelLibraryViewState(snapshot: snapshot)) { [weak reader] in
                Task { @MainActor in
                    guard let reader, reader.view.window != nil, request.currentContext() != nil else { return }
                    Self.presentDownloads(on: reader, request: request, picker: picker)
                }
            }
            withExtendedLifetime(presentation) {
                _ = presentation.menu.popUp(positioning: nil,
                    at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), in: anchor)
            }
        }
    }

    private static func presentDownloads(on reader: NSViewController,
                                         request: ReaderVoicePickerRequest, picker: ReaderVoicePicker) {
        let controller = MacSettingsViewController(settings: request.settings, library: request.library,
            voiceModelsOnly: true, readerVoicePicker: picker)
        controller.preferredContentSize = NSSize(width: 640, height: 520)
        reader.presentAsSheet(controller)
    }
}

/// Holds AppKit menu targets alive while tracking a reader voice choice.
@MainActor
private final class ReaderVoicePickerPresentation: NSObject {
    let menu = NSMenu(title: L10n.string("settings.voiceModels"))
    private let choices: [ReaderVoicePicker.Choice]
    private let picker: ReaderVoicePicker
    private let downloads: () -> Void

    init(picker: ReaderVoicePicker, catalog: SpeechModelLibraryViewState, downloads: @escaping () -> Void) {
        self.picker = picker
        self.choices = picker.choices(from: catalog)
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
        menu.addItem(.separator())
        let item = NSMenuItem(title: L10n.string("settings.voiceModelDownloads"), action: #selector(showDownloads), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard choices.indices.contains(item.tag), choices[item.tag].available else { return }
        picker.choose(choices[item.tag].selection)
    }

    @objc private func showDownloads() { downloads() }
}
#endif
