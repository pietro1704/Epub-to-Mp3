import SwiftUI
#if os(iOS)
import UIKit
#endif

/// High-frequency scrubber isolated from `InstantReaderView`'s TextKit tree.
struct InstantReaderScrubber: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock
    @Binding var scrubberDragValue: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            Text(format(seconds: adjustedPosition))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
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
            .accessibilityLabel(L10n.string("instantReader.playbackPosition"))
            Text(format(seconds: adjustedDuration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    private var adjustedPosition: TimeInterval {
        AudioPlayer.rateAdjustedDuration(seconds: playbackClock.positionSeconds, rate: player.rate)
    }

    private var adjustedDuration: TimeInterval {
        AudioPlayer.rateAdjustedDuration(seconds: playbackClock.durationSeconds, rate: player.rate)
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

/// Sleep-timer menu isolated from the reader's high-frequency view tree.
struct InstantReaderSleepTimerMenu: View {
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock

    var body: some View {
        Section(L10n.string("player.sleepTimer")) {
            ForEach([0, 5, 15, 30, 45, 60], id: \.self) { mins in
                Button {
                    player.setSleepTimer(seconds: TimeInterval(mins * 60))
                } label: {
                    HStack {
                        Text(mins == 0
                                ? L10n.string("player.sleepTimerOption.off")
                                : L10n.string("instantReader.sleepMinutes", mins))
                        if mins == 0, playbackClock.sleepTimerRemaining <= 0 {
                            Image(systemName: "checkmark")
                        } else if mins != 0,
                                  abs(playbackClock.sleepTimerRemaining - TimeInterval(mins * 60)) < 60 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if playbackClock.sleepTimerRemaining > 0 {
                Text(L10n.string(
                    "instantReader.sleepActive",
                    formatSleepTimer(playbackClock.sleepTimerRemaining)
                ))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func formatSleepTimer(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        return String(format: "%d:%02d", minutes, total % 60)
    }
}
