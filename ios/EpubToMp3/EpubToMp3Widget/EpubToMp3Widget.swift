import WidgetKit
import SwiftUI

// MARK: - Legacy compatibility: keep the old EpubToMp3Widget kind alive
// ============================================================================

/// Backwards-compatible widget using the original "EpubToMp3Widget" kind
/// string. If a user had the old widget on their home screen, this ensures
/// it keeps working after the update. Identical to `NowPlayingWidget` in
/// behaviour — the only difference is the `kind` identifier.
@available(iOS 17.0, *)
struct EpubToMp3Widget: Widget {
    let kind = "EpubToMp3Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDeepLinks.player(bookId: entry.bookId))
        }
        .configurationDisplayName("Now Playing")
        .description("Control playback or jump back into your audiobook.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// ============================================================================
