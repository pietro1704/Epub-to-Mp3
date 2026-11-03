#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Recovery stays in alerts and never writes global preferences or installs models.
@MainActor
enum TtsRecoveryAlert {
    struct Choice { let candidate: TtsRecoveryCandidate; let language: String }

    static func choose(for error: Error, isCurrent: @escaping () -> Bool) async -> Choice? {
        guard let mismatch = TtsLanguageMismatch.decode(error) else { return nil }
        let candidates: [TtsRecoveryCandidate]
        do { candidates = try await SpeechModelLibraryClient.shared.recoveryCandidates(for: mismatch) }
        catch { _ = AppErrorReporter.message(error, context: "Speech model recovery"); candidates = [] }
        guard !Task.isCancelled, isCurrent() else { return nil }
        guard let suggested = candidates.first else {
            await inform(L10n.string("tts.recovery.none", mismatch.language), isCurrent: isCurrent)
            return nil
        }
        let selected = await select(candidates, suggested: suggested, language: mismatch.language)
        guard !Task.isCancelled, isCurrent(), let selected else { return nil }
        return Choice(candidate: selected, language: mismatch.language)
    }

    private static func select(_ candidates: [TtsRecoveryCandidate], suggested: TtsRecoveryCandidate?, language: String) async -> TtsRecoveryCandidate? {
        let title = L10n.string("tts.recovery.title")
        let message = suggested.map { L10n.string("tts.recovery.message", language, $0.name) }
            ?? L10n.string("tts.recovery.choose")
        #if os(iOS)
        guard let controller = presenter(), controller.presentedViewController == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let suggested {
                let action = UIAlertAction(title: L10n.string("tts.recovery.use", suggested.name), style: .default) { _ in
                    continuation.resume(returning: suggested)
                }
                alert.addAction(action)
                alert.preferredAction = action
                alert.addAction(UIAlertAction(title: L10n.string("tts.recovery.choose"), style: .default) { _ in
                    controller.dismiss(animated: true) {
                        Task { @MainActor in
                            let choice = await select(candidates, suggested: nil, language: language)
                            continuation.resume(returning: choice)
                        }
                    }
                })
            } else {
                for candidate in candidates {
                    alert.addAction(UIAlertAction(title: candidate.name, style: .default) { _ in continuation.resume(returning: candidate) })
                }
            }
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { _ in continuation.resume(returning: nil) })
            controller.present(alert, animated: true)
        }
        #elseif os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let suggested {
            alert.addButton(withTitle: L10n.string("tts.recovery.use", suggested.name))
            alert.addButton(withTitle: L10n.string("tts.recovery.choose"))
            alert.addButton(withTitle: L10n.string("common.cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { return suggested }
            if response == .alertSecondButtonReturn { return await select(candidates, suggested: nil, language: language) }
            return nil
        }
        for candidate in candidates { alert.addButton(withTitle: candidate.name) }
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return candidates.indices.contains(index) ? candidates[index] : nil
        #else
        return nil
        #endif
    }

    private static func inform(_ message: String, isCurrent: () -> Bool) async {
        guard isCurrent() else { return }
        #if os(iOS)
        guard let controller = presenter(), controller.presentedViewController == nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: L10n.string("tts.recovery.title"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { _ in continuation.resume() })
            controller.present(alert, animated: true)
        }
        #elseif os(macOS)
        let alert = NSAlert()
        alert.messageText = L10n.string("tts.recovery.title")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
        #endif
    }

    #if os(iOS)
    private static func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    #endif
}
