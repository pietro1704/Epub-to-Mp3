#if os(iOS)
import UIKit

@MainActor
enum SettingsAlertPresentation {
    static func actionSheet(
        _ alert: UIAlertController,
        on controller: UIViewController,
        tableView: UITableView,
        source: IndexPath
    ) {
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView
        alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: source)
        controller.present(alert, animated: true)
    }

    static func info(on controller: UIViewController, title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("library.ok"), style: .default))
        controller.present(alert, animated: true)
    }

    static func destructive(
        on controller: UIViewController,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

    static func confirmModelInstall(
        _ entry: SpeechModelSnapshot.Entry,
        state: SpeechModelLibraryViewState,
        configuredSelections: [TtsSelection],
        termsAcceptance: SpeechModelTermsAcceptanceStore,
        on controller: UIViewController,
        install: @escaping (String?) -> Void
    ) {
        let details = state.details(for: entry, configuredSelections: configuredSelections)
        let needsTerms = entry.licence.requiresAcceptance
            && !termsAcceptance.isAccepted(
                modelID: entry.identity.modelID,
                fingerprint: entry.licence.termsFingerprint
            )
        guard needsTerms else {
            presentInstallConfirmation(
                entry, state: state, details: details, on: controller, install: install
            )
            return
        }
        guard let fingerprint = entry.licence.termsFingerprint else {
            info(
                on: controller,
                title: state.installTitle(for: entry),
                message: SpeechModelInstallationError.termsAcceptanceRequired(entry.identity.modelID)
                    .localizedDescription
            )
            return
        }
        let evidence = entry.licence.evidenceURL.map { "\n\($0.absoluteString)" } ?? ""
        let alert = UIAlertController(
            title: L10n.string("settings.modelTerms.acceptTitle"),
            message: details + evidence,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("settings.modelTerms.accept"), style: .default) { _ in
            termsAcceptance.accept(modelID: entry.identity.modelID, fingerprint: fingerprint)
            controller.dismiss(animated: true) {
                presentInstallConfirmation(
                    entry, state: state, details: details, on: controller, install: install
                )
            }
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

    static func confirmModelRemoval(
        _ entry: SpeechModelSnapshot.Entry,
        state: SpeechModelLibraryViewState,
        on controller: UIViewController,
        remove: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: L10n.string("settings.modelRemove.confirmTitle", state.displayName(for: entry)),
            message: L10n.string("settings.modelRemove.confirmMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.remove"), style: .destructive) { _ in
            remove()
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

    private static func presentInstallConfirmation(
        _ entry: SpeechModelSnapshot.Entry,
        state: SpeechModelLibraryViewState,
        details: String,
        on controller: UIViewController,
        install: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(
            title: state.installTitle(for: entry), message: details, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("settings.modelInstall.confirm"), style: .default) { _ in
            install(entry.licence.requiresAcceptance ? entry.licence.termsFingerprint : nil)
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

}
#endif
