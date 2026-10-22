#if os(iOS)
import UIKit

@MainActor
enum ReaderListeningAlerts {
    static func present(_ error: Error, from controller: UIViewController, library: @escaping () -> LibraryStore?) {
        if let pressure = error as? StoragePressureError {
            presentStorageManagementAlert(pressure, from: controller, library: library)
            return
        }
        let alert = UIAlertController(title: L10n.string("bookDetail.listenStart"),
            message: AppErrorReporter.message(error, context: "Reader listening"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        controller.present(alert, animated: true)
    }

    private static func presentStorageManagementAlert(_ error: StoragePressureError, from controller: UIViewController, library: @escaping () -> LibraryStore?) {
        let alert = UIAlertController(
            title: L10n.string("settings.insufficientStorageTitle"),
            message: AppErrorReporter.message(error, context: #function),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.string("settings.manageDownloads"),
            style: .default
        ) { [weak controller] _ in
            guard let controller, let library = library() else { return }
            let downloads = LocalAudioDownloadsScreenController(library: library)
            controller.present(UINavigationController(rootViewController: downloads), animated: true)
        })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }
}
#endif
