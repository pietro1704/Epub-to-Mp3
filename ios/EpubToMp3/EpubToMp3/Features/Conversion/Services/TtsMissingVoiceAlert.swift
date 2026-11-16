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
            return TtsRecoveryCandidate(name: voice.name, selection: .selected(.system))
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
        controller.present(progress, animated: true)
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

    /// Opens the voice-model destination on the Settings tab, showing the book's
    /// language. The destination is pushed; Settings itself never expands inline.
    static func openSettings(language: String, snapshot: SpeechModelSnapshot?, from controller: UIViewController,
                             client: SpeechModelLibraryClient) async {
        func findTabs(_ root: UIViewController?) -> UITabBarController? {
            guard let root else { return nil }
            if let tabs = root as? UITabBarController { return tabs }
            return root.children.compactMap { findTabs($0) }.first
        }
        guard let tabs = controller.tabBarController ?? findTabs(controller.view.window?.rootViewController),
              let navigation = tabs.viewControllers?.compactMap({ $0 as? UINavigationController }).first(where: {
                  $0.viewControllers.first is SettingsScreenController
              }), let settings = navigation.viewControllers.first as? SettingsScreenController else { return }
        var targetSnapshot = snapshot
        let languageTags = snapshot?.entries.filter { $0.compatibility.compatible }
            .flatMap { $0.languageEvidence.exactTags.map(\.tag) }.sorted() ?? []
        if let tag = languageTags.first(where: { $0 == language }) ?? languageTags.first {
            targetSnapshot = (try? await client.setStudyLanguage(tag)) ?? snapshot
        }
        let destination = settings.makeVoiceModelsDestination()
        destination.loadViewIfNeeded()
        if let targetSnapshot {
            destination.speechModelsTask?.cancel()
            destination.speechModelState = SpeechModelLibraryViewState(snapshot: targetSnapshot)
            destination.observeInstalls(in: targetSnapshot.entries)
        }
        navigation.popToRootViewController(animated: false)
        navigation.pushViewController(destination, animated: false)
        tabs.selectedViewController = navigation
        destination.tableView.reloadData()
        let groups = destination.modelLanguageSections
        if let index = groups.firstIndex(where: { $0.entries.contains { $0.compatibility.compatible } }),
           !groups[index].entries.isEmpty {
            destination.tableView.scrollToRow(at: IndexPath(row: 0, section: index + 1), at: .top, animated: false)
        }
    }

    private static func dismissAlert(on controller: UIViewController) async {
        guard controller.presentedViewController is UIAlertController else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }
}
#endif
