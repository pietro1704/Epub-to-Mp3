#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

// Conversion Live Activity (iOS 16.2+).
// `ConversionActivityAttributes` lives in `EpubToMp3/Models/` and is a source of
// both the main app and the widget extension targets.

// MARK: - Widget

struct ConversionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConversionActivityAttributes.self) { context in
            // Lock screen / banner expanded view
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(.tint)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.bookTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if let chapterName = context.state.currentChapterName, !chapterName.isEmpty {
                            Text(chapterName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ProgressView(value: context.state.progressFraction)
                            .tint(Color.accentColor)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Book cover placeholder (no artwork decode in widget)
                Image(systemName: "waveform.path")
                    .foregroundStyle(.tint)
                    .font(.caption)
            } compactTrailing: {
                Text(context.state.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            } minimal: {
                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(context.state.progressFraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }
}

// MARK: - Lock Screen / Banner Layout

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<ConversionActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "waveform.path")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.bookTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let chapterName = context.state.currentChapterName, !chapterName.isEmpty {
                    Text(chapterName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: context.state.progressFraction)
                    .tint(Color.accentColor)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.statusLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                Text("Converting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
#endif
