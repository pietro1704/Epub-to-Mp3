#if os(iOS)
import UIKit

@MainActor
enum TocAudioAvailabilityPresentation {
    struct Row {
        let title: String
        let zeroBasedIndex: Int
        let charCount: Int?
        let isCurrent: Bool
        let audioReady: Bool
        let downloaded: Bool
        let artifactState: LocalAudioArtifactStore.ArtifactState?
        let schedulerState: LocalAudioConversionScheduler.WorkState?
    }

    static func configure(_ cell: UITableViewCell, row: Row, isFocused: Bool, tintColor: UIColor,
                          onDownload: ((Int) -> Void)?, onRemoveDownload: ((Int, String) -> Void)?) {
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        var secondary: [String] = []
        if let charCount = row.charCount {
            secondary.append(L10n.string("toc.charsCount", charCount))
        }
        if row.downloaded {
            secondary.append(L10n.string("toc.downloaded"))
        } else if let status = TocChapterPresentation.artifactStatusText(for: row.artifactState) {
            secondary.append(status)
        } else if TocChapterPresentation.usesSchedulerStatus(
            artifactState: row.artifactState,
            schedulerState: row.schedulerState
        ),
                  let status = TocChapterPresentation.schedulerStatusText(for: row.schedulerState) {
            secondary.append(status)
        } else if !row.audioReady {
            secondary.append(L10n.string("toc.textOnly"))
        }
        content.secondaryText = secondary.joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 2
        content.textProperties.font = .preferredFont(forTextStyle: isFocused ? .headline : .body)
        content.textProperties.color = isFocused ? tintColor : .label
        content.secondaryTextProperties.color = isFocused ? tintColor : .secondaryLabel
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = isFocused ? tintColor.withAlphaComponent(0.12) : .clear
        cell.backgroundConfiguration = background
        cell.accessoryType = row.isCurrent ? .checkmark : .none
        cell.accessoryView = makeAccessoryView(for: row, onDownload: onDownload, onRemoveDownload: onRemoveDownload)
        cell.accessibilityLabel = row.title
        cell.accessibilityValue = row.downloaded
            ? L10n.string("toc.downloaded")
            : (TocChapterPresentation.artifactStatusText(for: row.artifactState)
                ?? (TocChapterPresentation.usesSchedulerStatus(
                    artifactState: row.artifactState,
                    schedulerState: row.schedulerState
                ) ? TocChapterPresentation.schedulerStatusText(for: row.schedulerState) : nil)
                ?? (row.audioReady ? L10n.string("player.downloadChapter") : L10n.string("toc.textOnly")))
        cell.selectionStyle = .default
        cell.isUserInteractionEnabled = true
        cell.accessibilityTraits = row.isCurrent ? [.button, .selected] : .button
    }

    static func makeAccessoryView(for row: Row, onDownload: ((Int) -> Void)?, onRemoveDownload: ((Int, String) -> Void)?) -> UIView? {
        guard let onDownload else { return nil }
        let button = UIButton(type: .system)
        let usesSchedulerStatus = TocChapterPresentation.usesSchedulerStatus(
            artifactState: row.artifactState,
            schedulerState: row.schedulerState
        )
        let isWorking = row.artifactState == .generating
            || row.artifactState == .waitingForWiFi
            || (usesSchedulerStatus && (row.schedulerState == .waitingForWiFi || row.schedulerState == .waitingForResources))
        let imageName: String
        if row.downloaded {
            imageName = "checkmark.circle.fill"
        } else if row.artifactState == .generating {
            imageName = "arrow.triangle.2.circlepath.circle"
        } else if row.artifactState == .waitingForWiFi {
            imageName = "wifi"
        } else if usesSchedulerStatus, row.schedulerState == .waitingForWiFi {
            imageName = "wifi"
        } else if usesSchedulerStatus, row.schedulerState == .waitingForResources {
            imageName = "pause.circle"
        } else if usesSchedulerStatus, row.schedulerState == .queued {
            imageName = "clock"
        } else if usesSchedulerStatus, row.schedulerState == .generating {
            imageName = "arrow.triangle.2.circlepath.circle"
        } else if row.artifactState == .failed {
            imageName = "arrow.clockwise.circle"
        } else {
            imageName = "arrow.down.circle"
        }
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.tintColor = .secondaryLabel
        button.isEnabled = !isWorking && (row.downloaded ? onRemoveDownload != nil : row.audioReady)
        button.accessibilityLabel = row.downloaded
            ? L10n.string("toc.removeDownload")
            : L10n.string("player.downloadChapter")
        button.accessibilityIdentifier = "reader.toc.download.\(row.zeroBasedIndex)"
        button.accessibilityValue = row.downloaded ? L10n.string("toc.downloaded") : nil
        // UITableViewCell owns the frame of its accessoryView. Constraints on
        // the button make it escape the trailing accessory slot on iOS 18.
        button.frame.size = CGSize(width: 44, height: 44)
        if isWorking {
            button.accessibilityValue = TocChapterPresentation.artifactStatusText(for: row.artifactState)
                ?? (usesSchedulerStatus ? TocChapterPresentation.schedulerStatusText(for: row.schedulerState) : nil)
        } else if row.downloaded, let onRemoveDownload {
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: [
                UIAction(
                    title: L10n.string("toc.removeDownload"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    onRemoveDownload(row.zeroBasedIndex, row.title)
                }
            ])
        } else {
            button.addAction(UIAction { _ in
                onDownload(row.zeroBasedIndex)
            }, for: .touchUpInside)
        }
        return button
    }

}
#endif
