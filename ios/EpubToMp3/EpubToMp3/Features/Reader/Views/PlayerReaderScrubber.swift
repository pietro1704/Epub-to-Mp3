import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Transport-only scrubber for `PlayerReaderView`.
///
/// Keeping the clock observer below the reader parent prevents a 250 ms
/// playback tick from rebuilding TextKit pages and their layout tree.
struct PlayerReaderScrubber: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Binding var scrubberDragValue: TimeInterval?

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubberDragValue ?? playbackClock.positionSeconds },
                    set: { scrubberDragValue = $0 }
                ),
                in: 0...max(playbackClock.durationSeconds, 1),
                onEditingChanged: { editing in
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: editing ? .light : .medium)
                    generator.impactOccurred()
                    #endif
                    if !editing, let target = scrubberDragValue {
                        player.seek(to: target)
                        scrubberDragValue = nil
                    }
                }
            )
            HStack {
                Text(format(seconds: playbackClock.positionSeconds))
                Spacer()
                Text(format(seconds: playbackClock.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Timer-only transport badge. It observes the high-frequency clock without
/// invalidating the parent reader hierarchy.
struct PlayerReaderSleepTimerBadge: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock

    var body: some View {
        if playbackClock.sleepTimerRemaining > 0 {
            Button { player.cancelSleepTimer() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                    Text(formatSleepTimer(playbackClock.sleepTimerRemaining))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func formatSleepTimer(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
