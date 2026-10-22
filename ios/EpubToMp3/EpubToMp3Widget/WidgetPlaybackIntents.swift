import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget Intents (trampoline via App Group UserDefaults + Darwin notification)

/// Darwin notification name posted after writing an intent flag. The main
/// app registers a `CFNotificationCenter` observer for this on launch (see
/// `EpubToMp3App.registerWidgetIntentObserver`) so the flag is drained
/// immediately — including while the app is merely backgrounded (it holds
/// the `audio` UIBackgroundMode, so it isn't suspended during playback).
///
/// Without this, the flag was only drained on a `scenePhase` transition to
/// `.active`, which never fires if the app is already frontmost/backgrounded
/// when the widget button is tapped — the widget button appeared to do
/// nothing.
/// Play/Pause: writes a flag the main app reads on foreground, and pings
/// it immediately via Darwin notification so it doesn't have to wait for
/// a scene-phase transition.
@available(iOS 16.0, *)
struct TogglePlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static var description: IntentDescription { IntentDescription("Toggles audio playback.") }
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        WidgetPlaybackCommand.togglePlayPause.send(defaults: WidgetSharedLibrary.defaults())
        return .result()
    }
}

/// Skip forward 30 seconds.
@available(iOS 16.0, *)
struct SkipForward30Intent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward 30s"
    static var description: IntentDescription { IntentDescription("Skips forward 30 seconds in the audiobook.") }
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        WidgetPlaybackCommand.skipForward30.send(defaults: WidgetSharedLibrary.defaults())
        return .result()
    }
}

// ============================================================================
