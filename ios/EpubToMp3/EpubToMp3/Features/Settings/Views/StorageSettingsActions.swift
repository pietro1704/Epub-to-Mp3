#if os(iOS)
import UIKit

@MainActor
final class StorageSettingsActions {
    private weak var controller: UITableViewController?
    private let library: LibraryStore
    private let storageSection: Int
    private let refreshStorageUsage: () -> Void

    init(controller: UITableViewController, library: LibraryStore, storageSection: Int, refreshStorageUsage: @escaping () -> Void) {
        self.controller = controller
        self.library = library
        self.storageSection = storageSection
        self.refreshStorageUsage = refreshStorageUsage
    }

    func handleSelection(row: Int) {
        guard let controller else { return }
        if row == 4 {
            controller.navigationController?.pushViewController(
                LocalAudioDownloadsScreenController(library: library),
                animated: true
            )
        } else if row == 5 {
            refreshStorageUsage()
            controller.tableView.reloadSections(IndexSet(integer: storageSection), with: .none)
        } else if row == 6 {
            SettingsAlertPresentation.destructive(on: controller,
                title: L10n.string("settings.clearTemporaryAudioConfirmTitle"),
                message: L10n.string("settings.clearTemporaryAudioConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                self?.clearTemporaryAudio()
            }
        } else if row == 7 {
            SettingsAlertPresentation.destructive(on: controller,
                title: L10n.string("settings.clearAllDownloadsConfirmTitle"),
                message: L10n.string("settings.clearAllDownloadsConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                self?.clearAllDownloads()
            }
        }
    }

    func clearAllDownloads() {
        Task { [weak self] in
            guard let self, let controller = self.controller else { return }
            do {
                try await AudioStorageMaintenance().clearAllDownloads()
                for var book in self.library.books where book.cachedOffline {
                    book.cachedOffline = false
                    self.library.update(book)
                }
            } catch {
                SettingsAlertPresentation.info(on: controller, title: L10n.string("settings.storageRemovalFailedTitle"),
                    message: L10n.string("settings.storageRemovalFailedMessage") + "\n\n" + AppErrorReporter.message(error, context: "Audio removal"))
            }
            self.refreshStorageUsage()
            self.controller?.tableView.reloadSections(IndexSet(integer: storageSection), with: .none)
        }
    }

    func clearTemporaryAudio() {
        Task { [weak self] in
            guard let self, let controller = self.controller else { return }
            do {
                try await AudioStorageMaintenance().clearTemporaryAudio()
            } catch {
                SettingsAlertPresentation.info(on: controller, title: L10n.string("settings.storageRemovalFailedTitle"),
                    message: L10n.string("settings.storageRemovalFailedMessage") + "\n\n" + AppErrorReporter.message(error, context: "Audio removal"))
            }
            self.refreshStorageUsage()
            self.controller?.tableView.reloadSections(IndexSet(integer: storageSection), with: .none)
        }
    }


}
#endif
