import SwiftUI

/// Modal sheet that surfaces live TTS conversion progress to the user.
///
/// Presented by `InstantReaderView` when the user taps the
/// "Generating audio…" status strip. Follows the HIG modal sheet pattern:
/// `.medium` detent by default, `.large` available by dragging, drag
/// indicator visible.
///
/// Sections:
///   1. Header   — book title + chapter name + elapsed time.
///   2. Event log — auto-scrolling list of `ConversionEvent`s.
///   3. Footer    — Cancel conversion (destructive) + Retry if error.
struct ConversionStatusSheet: View {

    @ObservedObject var status: ConversionStatus
    let bookTitle: String
    let onCancel: () -> Void
    let onRetry: () -> Void

    /// Drives the elapsed-time label without blocking the main runloop.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // CompatNavigationStack so the toolbar Cancel button works
        // on both iOS 15 (NavigationView) and iOS 16+ (NavigationStack).
        CompatNavigationStack {
            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Divider()

                eventList
                    .frame(maxHeight: .infinity)

                Divider()

                footerView
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .navigationTitle("Conversion Status")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { /* sheet dismissed by parent */ }
                }
            }
        }
        .compatPresentationDetents()
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Book title
            Text(bookTitle)
                .font(.headline)
                .lineLimit(1)

            // Chapter name
            if let chapter = status.currentChapterName, !chapter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(chapter)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if status.startedAt != nil {
                Text("Preparing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Elapsed time
            if let elapsed = elapsedLabel {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(elapsed)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Event list

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if status.events.isEmpty {
                        VStack(spacing: 8) {
                            if status.startedAt != nil {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for first audio chunk…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Conversion not started.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)
                    } else {
                        ForEach(status.events) { event in
                            eventRow(event)
                                .id(event.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: status.events.count) { _ in
                if let last = status.events.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: ConversionStatus.ConversionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.kind.systemImage)
                .font(.caption)
                .foregroundStyle(iconColor(for: event.kind))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.message)
                    .font(.caption)
                    .foregroundStyle(event.kind == .error ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(formatted(date: event.timestamp))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)

        Divider()
            .padding(.leading, 24)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            // Retry — only when there is a pending error.
            if status.lastError != nil {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("conversionStatus.retryButton")
            }

            Spacer()

            // Cancel conversion — destructive, HIG role.
            if status.startedAt != nil {
                Button(role: .destructive, action: onCancel) {
                    Label("Cancel conversion", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("conversionStatus.cancelButton")
            }
        }
    }

    // MARK: - Helpers

    private var elapsedLabel: String? {
        guard let start = status.startedAt else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0 else { return nil }
        let total = Int(elapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d elapsed", m, s)
    }

    private func formatted(date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func iconColor(for kind: ConversionStatus.EventKind) -> Color {
        switch kind {
        case .chunkStart:      return .accentColor.opacity(0.7)
        case .chunkComplete:   return .green
        case .chapterComplete: return .accentColor
        case .error:           return .red
        case .info:            return .secondary
        }
    }
}

#if DEBUG
#Preview("ConversionStatusSheet") {
    let status = ConversionStatus()
    Task { @MainActor in
        status.beginSession()
        status.setCurrentChapter(index: 0, name: "Chapter 1: The Shire")
        status.record(.info, "Starting chapter 1/12: The Shire")
        status.record(.chunkComplete, "ch0 segment 0 ready (18432 bytes)")
        status.record(.chunkComplete, "ch0 segment 1 ready (21120 bytes)")
        status.record(.chunkComplete, "ch0 segment 2 ready (19876 bytes)")
        status.record(.error, "Chapter 2 failed: Edge TTS timeout after 30s")
        status.record(.info, "Retrying chapter 2…")
    }
    return ConversionStatusSheet(
        status: status,
        bookTitle: "The Lord of the Rings",
        onCancel: {},
        onRetry: {}
    )
}
#endif
