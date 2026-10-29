#if os(iOS)
import UIKit

@MainActor
struct SettingsCellPresentation {
    let tableView: UITableView
    let settings: AppSettings
    let storageUsage: StorageUsageSnapshot
    let diagnosticsSession: StreamingDiagnosticsSession

    private static var platformMinimumLabel: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["MinimumOSVersion"] as? String, !version.isEmpty {
            return "iOS \(version)+"
        }
        return "iOS 15.0+"
    }
    func storageCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = nil
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.storageUsage")
            content.secondaryText = "\(formatBytes(storageUsage.totalBytes)) / \(formatBytes(storageUsage.budgetBytes))"
            content.image = UIImage(systemName: "internaldrive")
            cell.selectionStyle = .none
        case 1:
            content.text = L10n.string("settings.offlineAudio")
            content.secondaryText = formatBytes(storageUsage.offlineAudioBytes)
            cell.selectionStyle = .none
        case 2:
            content.text = L10n.string("settings.ttsCache")
            content.secondaryText = formatBytes(storageUsage.ttsCacheBytes)
            cell.selectionStyle = .none
        case 3:
            content.text = L10n.string("settings.storageTotal")
            content.secondaryText = formatBytes(storageUsage.totalBytes)
            cell.selectionStyle = .none
        case 4:
            content.text = L10n.string("settings.manageDownloads")
            content.secondaryText = L10n.string("settings.manageDownloadsDescription")
            content.image = UIImage(systemName: "books.vertical")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.manageDownloads"
        case 5:
            content.text = L10n.string("settings.refreshStorage")
            content.image = UIImage(systemName: "arrow.clockwise")
        case 6:
            content.text = L10n.string("settings.clearTemporaryAudio")
            content.image = UIImage(systemName: "trash")
            content.textProperties.color = .systemRed
        default:
            content.text = L10n.string("settings.clearAllDownloads")
            content.image = UIImage(systemName: "trash")
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    func advancedCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = nil
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.recentJobs")
            content.secondaryText = L10n.string("settings.recentJobsDescription")
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        case 1:
            content.text = L10n.string("settings.telemetry")
            content.secondaryText = L10n.string("settings.telemetryDescription")
            content.image = UIImage(systemName: "speedometer")
        case 2:
            content.text = L10n.string("settings.exportPerformanceDiagnostics")
            content.secondaryText = L10n.string("settings.exportPerformanceDiagnosticsDescription")
            content.image = UIImage(systemName: "square.and.arrow.up")
            cell.accessibilityIdentifier = "settings.exportPerformanceDiagnostics"
        case 3:
            content.text = L10n.string(diagnosticsSession.isActive
                ? "settings.stopStreamingDiagnostics" : "settings.recordStreamingDiagnostics")
            content.secondaryText = L10n.string(diagnosticsSession.isActive
                ? "settings.streamingDiagnosticsActive" : "settings.streamingDiagnosticsInactive")
            content.image = UIImage(systemName: "waveform.path")
            cell.accessibilityIdentifier = "settings.recordStreamingDiagnostics"
            cell.accessoryType = .none
        default:
            return UITableViewCell()
        }
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        return cell
    }

    func aboutCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.bundleIdentifier")
            content.secondaryText = "com.pietrocode.epubtomp3"
            cell.selectionStyle = .none
        case 1:
            content.text = L10n.string("settings.platform")
            content.secondaryText = Self.platformMinimumLabel
            cell.selectionStyle = .none
        default:
            content.text = L10n.string("settings.projectOnGithub")
            content.image = UIImage(systemName: "arrow.up.right.square")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

}
#endif
