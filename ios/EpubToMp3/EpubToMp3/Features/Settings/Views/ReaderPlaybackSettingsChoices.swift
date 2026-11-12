#if os(iOS)
import UIKit

@MainActor
final class ReaderPlaybackSettingsChoices {
    private weak var controller: UITableViewController?
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playbackSection: Int
    private let readerSection: Int

    init(controller: UITableViewController, settings: AppSettings, player: AudioPlayer,
         playbackSection: Int, readerSection: Int) {
        self.controller = controller
        self.settings = settings
        self.player = player
        self.playbackSection = playbackSection
        self.readerSection = readerSection
    }

    func handlePlaybackSelection(row: Int) {
        let forward = row == 0
        SettingsChoicePresentation.present(
            controller: controller,
            title: forward ? L10n.string("settings.skipForward") : L10n.string("settings.skipBackward"),
            options: [15, 30, 45, 60].map { (L10n.string("settings.seconds", $0), Double($0)) },
            currentValue: forward ? settings.playbackForwardSeconds : settings.playbackBackwardSeconds
        ) { [weak self] value in
            guard let self else { return }
            if forward {
                self.settings.playbackForwardSeconds = value
            } else {
                self.settings.playbackBackwardSeconds = value
            }
            self.player.refreshRemoteSkipIntervals()
            self.controller?.tableView.reloadSections(IndexSet(integer: self.playbackSection), with: .none)
        }
    }

    func handleReaderSelection(row: Int) {
        switch row {
        case 0: break // Point-valued rows are adjusted by their native preset slider.
        case 1:
            controller?.navigationController?.pushViewController(
                ReaderFontChoiceController(settings: settings) { [weak self] in
                    self?.controller?.tableView.reloadData()
                }, animated: true)
        case 2:
            SettingsChoicePresentation.present(
            controller: controller,
                title: L10n.string("settings.theme"),
                options: ReaderTheme.allCases.map { ($0.displayName, $0) },
                currentValue: settings.readerTheme
            ) { [weak self] value in
                self?.settings.readerTheme = value
            }
        case 3:
            SettingsChoicePresentation.present(
            controller: controller,
                title: L10n.string("settings.layout"),
                options: ReaderLayout.allCases.map { ($0.displayName, $0) },
                currentValue: settings.readerLayout
            ) { [weak self] value in
                self?.settings.readerLayout = value
            }
        case 4, 5: break
        case 6:
            settings.readerAutoScroll.toggle()
        default:
            settings.readerAudioTrackingEnabled.toggle()
        }
        controller?.tableView.reloadSections(IndexSet(integer: readerSection), with: .none)
    }


}
#endif
