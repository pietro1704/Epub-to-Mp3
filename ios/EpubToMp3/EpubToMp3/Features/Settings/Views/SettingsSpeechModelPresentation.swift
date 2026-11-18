#if os(iOS)
import UIKit

/// The voice-model destination lists its runtime rows first and then one section
/// per language. Settings itself keeps a single summary row and no model rows.
extension SettingsScreenController {
    func reloadSpeechModels() {
        speechModelsTask?.cancel()
        let client = speechModels
        speechModelsTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await client.snapshot()
                guard !Task.isCancelled else { return }
                self?.speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                self?.observeInstalls(in: snapshot.entries)
                self?.tableView.reloadData()
            } catch {
                // Fail closed: keep existing selections and the last valid presentation.
            }
        }
    }

    /// Presents a catalogue the caller already resolved, replacing the pending reload.
    func show(_ snapshot: SpeechModelSnapshot) {
        speechModelsTask?.cancel()
        speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
        observeInstalls(in: snapshot.entries)
        tableView.reloadData()
    }

    func settingsSection(at index: Int) -> SettingsSection? {
        voiceModelsOnly ? (index == 0 ? .runtime : nil) : SettingsSection(rawValue: index)
    }

    var modelLanguageSections: [SpeechModelLanguageSection] {
        voiceModelsOnly ? SpeechModelLanguageSection.sections(state: speechModelState) : []
    }

    /// An empty catalogue still shows one explanatory row after the runtime rows.
    var modelSectionCount: Int { max(modelLanguageSections.count, 1) }

    func modelRowCount(inSection section: Int) -> Int {
        let groups = modelLanguageSections
        if groups.isEmpty { return section == 1 ? 1 : 0 }
        return groups.indices.contains(section - 1) ? groups[section - 1].entries.count : 0
    }

    func modelEntry(at path: IndexPath) -> SpeechModelSnapshot.Entry? {
        let groups = modelLanguageSections
        let group = path.section - 1
        guard groups.indices.contains(group), groups[group].entries.indices.contains(path.row) else { return nil }
        return groups[group].entries[path.row]
    }

    func modelCell(at path: IndexPath, entry: SpeechModelSnapshot.Entry,
                   existingCell: UITableViewCell? = nil) -> UITableViewCell {
        RuntimeSettingsRows.cell(for: path, tableView: tableView, settings: settings,
            speechModels: speechModelState, installEvents: speechModelInstallEvents,
            termsAcceptance: termsAcceptance, controller: self,
            rowOverride: .model(entry), existingCell: existingCell)
    }

    /// The summary is the only runtime row in Settings and follows the primary
    /// voice row in the destination.
    var modelSummaryPath: IndexPath {
        let destinationRow = SpeechModelSettingsDisclosure().rows(modelCount: 0).firstIndex(of: .summary) ?? 0
        return IndexPath(row: voiceModelsOnly ? destinationRow : 0, section: SettingsSection.runtime.rawValue)
    }

    func applyInstallEvent(_ event: SpeechModelInstallEvent) {
        guard speechModelState.entries.contains(where: { $0.identity.modelID == event.modelID }) else { return }
        speechModelInstallEvents[event.modelID] = event
        // Configure the live cells directly: reloading a self-sizing section makes
        // UIKit replace rows and recompute estimated heights for every byte event.
        UIView.performWithoutAnimation {
            for path in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: path) else { continue }
                if let entry = modelEntry(at: path), entry.identity.modelID == event.modelID {
                    _ = modelCell(at: path, entry: entry, existingCell: cell)
                } else if path == modelSummaryPath {
                    _ = RuntimeSettingsRows.cell(for: path, tableView: tableView, settings: settings,
                        speechModels: speechModelState, installEvents: speechModelInstallEvents,
                        termsAcceptance: termsAcceptance, disclosure: modelDisclosure,
                        controller: self, rowOverride: .models, existingCell: cell)
                }
            }
            // Self-sizing invalidation is iOS 16+; re-measure the live rows without replacing them.
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }
}
#endif
