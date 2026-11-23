#if os(iOS)
import UIKit

@MainActor
enum TtsMissingVoiceAlert {
    enum Action { case recommended, settings, system, cancel }

    static func makeAlert(language: String, recommended: SpeechModelSnapshot.Entry?, systemAvailable: Bool,
                          perform: @escaping (Action) -> Void) -> UIAlertController {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
        var message = L10n.string("tts.missingVoice.message", languageName)
        if let recommended { message += "\n" + L10n.string("tts.missingVoice.recommended", recommended.presentation.modelName) }
        let alert = UIAlertController(title: L10n.string("tts.missingVoice.title"), message: message, preferredStyle: .alert)
        let download = UIAlertAction(title: L10n.string("tts.missingVoice.downloadRecommended"), style: .default) { _ in perform(.recommended) }
        download.isEnabled = recommended != nil
        alert.addAction(download)
        if download.isEnabled { alert.preferredAction = download }
        alert.addAction(UIAlertAction(title: L10n.string("tts.missingVoice.openSettings"), style: .default) { _ in perform(.settings) })
        let system = UIAlertAction(title: L10n.string("tts.missingVoice.system"), style: .default) { _ in perform(.system) }
        system.isEnabled = systemAvailable
        alert.addAction(system)
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { _ in perform(.cancel) })
        alert.view.accessibilityIdentifier = "tts.missingVoice.alert"
        return alert
    }

    static func choose(language: String, on controller: UIViewController,
                       client: SpeechModelLibraryClient = .shared,
                       isCurrent: @escaping () -> Bool) async -> TtsRecoveryCandidate? {
        let snapshot = try? await client.recoverySnapshot(language: language)
        guard !Task.isCancelled, isCurrent(), controller.presentedViewController == nil else { return nil }
        let recommended = snapshot.flatMap { TtsMissingVoicePolicy.recommended(in: $0) }
        let voices = TtsMissingVoicePreflight.installedSystemVoices()
        let systemVoice = InstalledSpeechVoicePolicy.select(language: language, voices: voices)
        let action = await withCheckedContinuation { continuation in
            controller.present(makeAlert(language: language, recommended: recommended, systemAvailable: systemVoice != nil) {
                continuation.resume(returning: $0)
            }, animated: true)
        }
        await dismissAlert(on: controller)
        guard !Task.isCancelled, isCurrent() else { return nil }
        switch action {
        case .cancel: return nil
        case .system:
            guard let voice = voices.first(where: { $0.identifier == systemVoice }) else { return nil }
            return TtsRecoveryCandidate(name: voice.name, selection: .systemDefault)
        case .settings:
            await openSettings(language: language, snapshot: snapshot, from: controller, client: client)
            return nil
        case .recommended:
            guard let snapshot, let recommended else { return nil }
            return await download(recommended, snapshot: snapshot, language: language,
                                  on: controller, client: client, isCurrent: isCurrent)
        }
    }

    private static func download(_ entry: SpeechModelSnapshot.Entry, snapshot: SpeechModelSnapshot, language: String,
                                 on controller: UIViewController, client: SpeechModelLibraryClient,
                                 isCurrent: @escaping () -> Bool) async -> TtsRecoveryCandidate? {
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let terms = SpeechModelTermsAcceptanceStore()
        let details = state.details(for: entry, configuredSelections: [])
            + (entry.licence.evidenceURL.map { "\n" + $0.absoluteString } ?? "")
        let confirmed = await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: state.installTitle(for: entry), message: details, preferredStyle: .alert)
            let key = entry.licence.requiresAcceptance ? "tts.missingVoice.acceptDownload" : "settings.modelInstall.confirm"
            alert.addAction(UIAlertAction(title: L10n.string(key), style: .default) { _ in continuation.resume(returning: true) })
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { _ in continuation.resume(returning: false) })
            controller.present(alert, animated: true)
        }
        await dismissAlert(on: controller)
        guard confirmed, !Task.isCancelled, isCurrent() else { return nil }
        if entry.licence.requiresAcceptance {
            guard let fingerprint = entry.licence.termsFingerprint else { return nil }
            terms.accept(modelID: entry.identity.modelID, fingerprint: fingerprint)
        }
        let installation = Task {
            try await client.install(modelID: entry.identity.modelID,
                acceptedTermsFingerprint: entry.licence.requiresAcceptance ? entry.licence.termsFingerprint : nil,
                language: language)
        }
        let progress = UIAlertController(title: L10n.string("tts.missingVoice.downloading"),
                                         message: entry.presentation.modelName, preferredStyle: .alert)
        progress.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { _ in
            installation.cancel()
        })
        // A fast failure must not dismiss the alert in the middle of its presentation.
        await withCheckedContinuation { continuation in
            controller.present(progress, animated: true) { continuation.resume() }
        }
        do {
            _ = try await installation.value
            await dismissAlert(on: controller)
            guard !Task.isCancelled, isCurrent() else { return nil }
            let updated = try await client.recoverySnapshot(language: language)
            return TtsRecoveryCandidate.available(in: updated, excluding: "").first {
                $0.selection.modelID == entry.identity.modelID
            }
        } catch {
            await dismissAlert(on: controller)
            guard !Task.isCancelled, isCurrent(), !(error is CancellationError) else { return nil }
            SettingsAlertPresentation.info(on: controller, title: state.installTitle(for: entry),
                message: AppErrorReporter.message(error, context: "Recommended speech model download"))
            return nil
        }
    }

    /// Shows the voice-model destination for the book's language as a sheet over the
    /// current screen. The reader covers the tab shell while a book is open, so
    /// switching tabs underneath it would show nothing.
    static func openSettings(language: String, snapshot: SpeechModelSnapshot?, from controller: UIViewController,
                             client: SpeechModelLibraryClient) async {
        func findSettings(_ root: UIViewController?) -> SettingsScreenController? {
            guard let root else { return nil }
            if let settings = root as? SettingsScreenController { return settings }
            return root.children.lazy.compactMap { findSettings($0) }.first
        }
        guard controller.presentedViewController == nil,
              let settings = findSettings(controller.view.window?.rootViewController) else { return }
        guard controller.presentedViewController == nil, controller.view.window != nil else { return }
        // The Models screen lists every language; open it on the book's language.
        let destination = settings.makeModelsScreen(focusLanguage: language)
        let navigation = UINavigationController(rootViewController: destination)
        destination.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        destination.navigationItem.rightBarButtonItem?.accessibilityIdentifier = "settings.voiceModels.done"
        navigation.view.accessibilityIdentifier = "tts.missingVoice.voiceModels"
        controller.present(navigation, animated: true)
    }

    private static func dismissAlert(on controller: UIViewController) async {
        guard controller.presentedViewController is UIAlertController else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }
}
#endif
