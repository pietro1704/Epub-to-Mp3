#if os(iOS)
import UIKit

@MainActor
enum SettingsAdvancedNavigation {
    static func destination(row: Int, settings: AppSettings, library: LibraryStore,
                            player: AudioPlayer, playbackClock: PlaybackClock) -> UIViewController? {
        switch row {
        case 0: return JobsListScreenController(settings: settings, library: library,
                                               player: player, playbackClock: playbackClock)
        case 1: return TelemetryScreenController(settings: settings)
        default: return nil
        }
    }
}
#endif
