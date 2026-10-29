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
        case 0:
            SettingsChoicePresentation.present(
            controller: controller,
                title: L10n.string("settings.fontSize"),
                options: (0...4).map { (L10n.string("settings.fontStep", $0 + 1, 5), $0) },
                currentValue: settings.readerFontSize
            ) { [weak self] value in
                self?.settings.readerFontSize = value
            }
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
        case 4:
            SettingsChoicePresentation.present(
            controller: controller,
                title: L10n.string("settings.lineSpacing"),
                options: stride(from: 0, through: 16, by: 2).map { ("\($0) pt", Double($0)) },
                currentValue: settings.readerLineSpacing
            ) { [weak self] value in
                self?.settings.readerLineSpacing = value
            }
        case 5:
            SettingsChoicePresentation.present(
            controller: controller,
                title: L10n.string("settings.margin"),
                options: stride(from: 16, through: 80, by: 4).map { ("\($0) pt", Double($0)) },
                currentValue: settings.readerMargin
            ) { [weak self] value in
                self?.settings.readerMargin = value
            }
        default:
            settings.readerAutoScroll.toggle()
        }
        controller?.tableView.reloadSections(IndexSet(integer: readerSection), with: .none)
    }


}
#endif
