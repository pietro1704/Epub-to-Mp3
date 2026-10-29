#if os(iOS)
import Foundation

enum SettingsSection: Int, CaseIterable {
    case runtime
    case backend
    case playback
    case reader
    case storage
    case advanced
    case about
    @MainActor
    func rowCount(speechModels: SpeechModelLibraryViewState, disclosure: SpeechModelSettingsDisclosure = .init()) -> Int {
        switch self {
        case .runtime:
            return RuntimeSettingsRows.rowCount(speechModels: speechModels, disclosure: disclosure)
        case .backend:
            return 2
        case .playback:
            return 2
        case .reader:
            return 7
        case .storage:
            return 8
        case .advanced:
            return 5
        case .about:
            return 3
        }
    }

    var title: String {
        switch self {
        case .runtime:
            return L10n.string("settings.audioEngine")
        case .backend:
            return L10n.string("settings.remoteBackend")
        case .playback:
            return L10n.string("settings.playback")
        case .reader:
            return L10n.string("settings.reader")
        case .storage:
            return L10n.string("settings.storage")
        case .advanced:
            return L10n.string("settings.advanced")
        case .about:
            return L10n.string("settings.about")
        }
    }

    func footer(settings: AppSettings) -> String? {
        switch self {
        case .runtime:
            return L10n.string("settings.audioEngineFooter")
        case .backend:
            return settings.remoteBackendControlsEnabled ? L10n.string("settings.remoteBackendFooterIOS") : nil
        case .playback:
            return L10n.string("settings.playbackFooter")
        case .reader:
            return L10n.string("settings.readerFooter")
        case .storage:
            return L10n.string("settings.storageFooter")
        case .advanced:
            return nil
        case .about:
            return nil
        }
    }
}
#endif
