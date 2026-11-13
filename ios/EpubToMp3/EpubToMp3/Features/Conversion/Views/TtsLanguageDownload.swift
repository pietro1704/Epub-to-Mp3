#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum TtsLanguageDownload {
    static func offer(for mismatch: TtsLanguageMismatch, isCurrent: @escaping () -> Bool) async -> TtsRecoveryAlert.Choice? {
        let client = SpeechModelLibraryClient.shared
        do {
            let snapshot = try await client.languageSnapshot(mismatch.language)
            guard !Task.isCancelled, isCurrent() else { return nil }
            let entries = snapshot.entries.filter {
                $0.compatibility.compatible && $0.distribution.installable
                    && $0.identity.provider != "edge" && $0.licence.validation != "rejected"
                    && $0.languageEvidence.routingTags.contains(where: {
                        $0.split(separator: "-").first?.lowercased() == mismatch.language.split(separator: "-").first?.lowercased()
                    })
            }
            guard let entry = entries.first else {
                await confirm(title: L10n.string("tts.recovery.title"),
                    message: L10n.string("tts.recovery.none", BookLanguagePicker.title(mismatch.language)), action: nil)
                return nil
            }
            let details = SpeechModelLibraryViewState(snapshot: snapshot).details(for: entry)
            let accepted = await confirm(title: L10n.string("language.downloadTitle", BookLanguagePicker.title(mismatch.language)),
                message: L10n.string("language.downloadMessage", entry.presentation.modelName) + "\n\n" + details,
                action: L10n.string("settings.modelInstall.confirm"))
            guard accepted, !Task.isCancelled, isCurrent() else { return nil }
            _ = try await client.install(modelID: entry.identity.modelID,
                acceptedTermsFingerprint: entry.licence.requiresAcceptance ? entry.licence.termsFingerprint : nil,
                language: mismatch.language)
            guard !Task.isCancelled, isCurrent() else { return nil }
            let candidates = try await client.recoveryCandidates(for: mismatch)
            guard let selected = candidates.first else { return nil }
            return .init(candidate: selected, language: mismatch.language)
        } catch {
            guard !Task.isCancelled, isCurrent() else { return nil }
            _ = await confirm(title: L10n.string("tts.recovery.title"),
                message: AppErrorReporter.message(error, context: "Install a language-compatible voice"), action: nil)
            return nil
        }
    }

    @discardableResult
    private static func confirm(title: String, message: String, action: String?) async -> Bool {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var presenter = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        guard let presenter else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let action {
                alert.addAction(UIAlertAction(title: action, style: .default) { _ in continuation.resume(returning: true) })
            }
            alert.addAction(UIAlertAction(title: L10n.string(action == nil ? "common.ok" : "common.cancel"), style: .cancel) { _ in continuation.resume(returning: false) })
            presenter.present(alert, animated: true)
        }
        #elseif os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let action { alert.addButton(withTitle: action) }
        alert.addButton(withTitle: L10n.string(action == nil ? "common.ok" : "common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn && action != nil
        #else
        return false
        #endif
    }
}
