import Foundation
import os.log

/// Owns the voice-model catalogue a settings screen shows: the current
/// snapshot, the live install events, one install observer per installable
/// model, and the confirmed install and remove operations. The iOS settings
/// screen and the macOS model library panel both use it; each keeps its own
/// confirmation dialogs, rendering and error presentation.
///
/// Installation starts only from `install`, which a screen calls after the
/// listener confirmed it; observing or reloading never installs a model.
/// Removal goes through the client, which refuses a model that is configured
/// or in use, so existing selections are preserved.
@MainActor
final class SpeechModelLibrarySession {
    enum Change: Equatable {
        /// A live install event for a catalogue model was stored.
        case installProgress(modelID: String)
        /// The catalogue or its operation finished; render everything again.
        case catalog
    }

    let client: SpeechModelLibraryClient
    var state: SpeechModelLibraryViewState
    private(set) var installEvents: [String: SpeechModelInstallEvent] = [:]
    var onChange: ((Change) -> Void)?
    /// A failed confirmed operation, with the title its alert uses.
    var onFailure: ((_ title: String, _ error: Error) -> Void)?

    private var reloadTask: Task<Void, Never>?
    private var observationTasks: [String: Task<Void, Never>] = [:]
    private let logRefreshFailure: (Error) -> Void
    private nonisolated static let log = Logger(subsystem: "epub2mp3", category: "SpeechModels")

    init(client: SpeechModelLibraryClient,
         logRefreshFailure: @escaping (Error) -> Void = SpeechModelLibrarySession.logRefreshFailure) {
        self.client = client
        self.logRefreshFailure = logRefreshFailure
        self.state = SpeechModelLibraryViewState(snapshot: client.initialSnapshot)
    }

    /// Only the error type is public; its description may contain paths.
    nonisolated static func logRefreshFailure(_ error: Error) {
        log.error("""
            Voice model installed but the catalogue refresh failed \
            (\(String(describing: type(of: error)), privacy: .public)): \
            \(String(describing: error), privacy: .private)
            """)
    }

    deinit {
        reloadTask?.cancel()
        observationTasks.values.forEach { $0.cancel() }
    }

    /// Reads the catalogue again. A failed read keeps the last valid state.
    func reload() {
        reloadTask?.cancel()
        let client = client
        reloadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await client.snapshot()
                guard !Task.isCancelled else { return }
                self?.show(snapshot, cancellingReload: false)
            } catch {
                // Fail closed: keep existing selections and the last valid presentation.
            }
        }
    }

    /// Presents a catalogue the caller already resolved, replacing a pending reload.
    func show(_ snapshot: SpeechModelSnapshot) {
        show(snapshot, cancellingReload: true)
    }

    private func show(_ snapshot: SpeechModelSnapshot, cancellingReload: Bool) {
        if cancellingReload { reloadTask?.cancel() }
        state = SpeechModelLibraryViewState(snapshot: snapshot)
        observeInstalls(in: snapshot.entries)
        onChange?(.catalog)
    }

    /// Stores an install event for a model in the current catalogue and
    /// returns whether it was accepted; events for other models are ignored.
    @discardableResult
    func apply(_ event: SpeechModelInstallEvent) -> Bool {
        guard state.entries.contains(where: { $0.identity.modelID == event.modelID }) else { return false }
        installEvents[event.modelID] = event
        return true
    }

    /// Replaces every observer with one per installable entry.
    func observeInstalls(in entries: [SpeechModelSnapshot.Entry]) {
        observationTasks.values.forEach { $0.cancel() }
        observationTasks.removeAll()
        let client = client
        for entry in entries where entry.distribution.installable {
            let modelID = entry.identity.modelID
            observationTasks[modelID] = Task { [weak self] in
                guard !Task.isCancelled else { return }
                let events = await client.watchInstall(modelID: modelID)
                for await event in events {
                    guard !Task.isCancelled else { return }
                    if self?.apply(event) == true { self?.onChange?(.installProgress(modelID: modelID)) }
                    guard event.stage == .completed else { continue }
                    if let snapshot = try? await client.snapshot() {
                        guard !Task.isCancelled else { return }
                        self?.installEvents.removeValue(forKey: modelID)
                        self?.state = SpeechModelLibraryViewState(snapshot: snapshot)
                    }
                    self?.onChange?(.catalog)
                }
            }
        }
    }

    /// Starts a confirmed installation independently of the presenting
    /// screen's lifetime. When the model installs but the catalogue cannot be
    /// read afterwards, the failure is logged rather than reported as a failed
    /// installation; the next snapshot or observed event refreshes the list.
    @discardableResult
    func install(_ entry: SpeechModelSnapshot.Entry, acceptedTermsFingerprint: String?) -> Task<Void, Never> {
        let client = client
        let modelID = entry.identity.modelID
        let title = state.installTitle(for: entry)
        return Task { [weak self] in
            do {
                _ = try await client.install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint)
                guard self != nil else { return }
                do {
                    let snapshot = try await client.snapshot()
                    self?.state = SpeechModelLibraryViewState(snapshot: snapshot)
                    self?.observeInstalls(in: snapshot.entries)
                } catch {
                    self?.logRefreshFailure(error)
                }
            } catch is CancellationError {
                // Cancellation is already rendered by the operation event.
            } catch {
                self?.onFailure?(title, error)
            }
            self?.onChange?(.catalog)
        }
    }

    /// Removes a confirmed model. The client refuses configured or in-use models.
    @discardableResult
    func remove(_ entry: SpeechModelSnapshot.Entry, configuredSelections: [TtsSelection]) -> Task<Void, Never> {
        let client = client
        let modelID = entry.identity.modelID
        return Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.remove(modelID: modelID, configuredSelections: configuredSelections)
                installEvents.removeValue(forKey: modelID)
                state = SpeechModelLibraryViewState(snapshot: snapshot)
                onChange?(.catalog)
            } catch {
                onFailure?(L10n.string("settings.modelRemove.failed"), error)
            }
        }
    }
}
