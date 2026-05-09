import SwiftUI

/// Modal player surfaced from `JobDetailView`. Shows the current
/// chapter, scrubber, transport controls, and a speed selector.
struct PlayerView: View {
    let snapshot: JobSnapshot
    let backendBaseURL: URL?
    @State private var player = AudioPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                artwork
                titleBlock
                scrubber
                transport
                speedPicker
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Now playing")
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { player.pause(); dismiss() }
                }
            }
            .onAppear {
                if player.snapshot?.jobId != snapshot.jobId {
                    player = AudioPlayer(backendBaseURL: backendBaseURL)
                    player.play(snapshot: snapshot, startingAt: 0)
                }
            }
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.tint.opacity(0.15))
            Image(systemName: "headphones")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
        }
        .frame(width: 220, height: 220)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(snapshot.bookTitle ?? "Audiobook")
                .font(.headline)
                .lineLimit(1)
            Text(currentChapterLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private var currentChapterLabel: String {
        let chapters = snapshot.playableChapters
        guard player.currentChapterIndex < chapters.count else { return "—" }
        return chapters[player.currentChapterIndex].displayTitle
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { player.positionSeconds },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.durationSeconds, 1)
            )
            HStack {
                Text(format(seconds: player.positionSeconds))
                Spacer()
                Text(format(seconds: player.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
        }
        .tint(.primary)
    }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(
            get: { player.rate },
            set: { player.setRate($0) }
        )) {
            ForEach(PlaybackRate.allCases) { rate in
                Text(rate.label).tag(rate)
            }
        }
        .pickerStyle(.segmented)
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

#Preview("Player") {
    PlayerView(
        snapshot: JobSnapshot.previewSample,
        backendBaseURL: URL(string: "http://localhost:8000")
    )
}

