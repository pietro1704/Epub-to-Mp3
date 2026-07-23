import SwiftUI
#if os(iOS)
import UIKit
import MediaPlayer
#endif

/// Modal player surfaced from `JobDetailView`. Shows the current
/// chapter, scrubber, transport controls, and a speed selector.
struct PlayerView: View {
    let snapshot: JobSnapshot
    let backendBaseURL: URL?
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject private var playbackClock: PlaybackClock

    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    private var readerChapterIndex: Int { readerCoordinator.anchor.chapterIndex }
    private var readerPageRatio: Double? { readerCoordinator.anchor.pageRatio }

    @State private var scrubberDragValue: TimeInterval?
    @State private var showingRatePicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                artwork
                titleBlock
                scrubber
                transport
                speedPicker
                Spacer()
            }
            // 24pt sits on top of the system safe-area inset so artwork
            // and transport controls stay clear of the notch in
            // landscape iPhone.
            .compatHorizontalSafeAreaPadding(24)
            .navigationTitle(L10n.string("reader.nowPlaying"))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("player.close")) { player.pause(); dismiss() }
                }
            }
            .onAppear {
                if player.snapshot?.jobId != snapshot.jobId {
                    player.backendBaseURL = backendBaseURL
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
            Text(snapshot.bookTitle ?? L10n.string("player.audiobookFallback"))
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
        guard player.snapshot != nil else { return "—" }
        return player.effectiveChapterTitle
    }

    private var scrubber: some View {
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
            .accessibilityLabel(L10n.string("player.playbackPosition"))
            HStack {
                Text(format(seconds: AudioPlayer.rateAdjustedDuration(
                    seconds: playbackClock.positionSeconds,
                    rate: player.rate
                )))
                Spacer()
                Text(format(seconds: AudioPlayer.rateAdjustedDuration(
                    seconds: playbackClock.durationSeconds,
                    rate: player.rate
                )))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            // VoiceOver double-announces position via the Slider value
            // and again via these labels. Hide from the a11y tree so
            // each tick of the scrubber doesn't trigger two reads.
            .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: 32) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.string("player.previousChapter"))
            Button { handlePlayTap() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(
                player.isPlaying
                    ? L10n.string("player.pause")
                    : L10n.string("player.play")
            )
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.string("player.nextChapter"))
        }
        .tint(.primary)

    }

    private func handlePlayTap() {
        player.togglePlayPause()
    }

    private var speedPicker: some View {
        Button {
            showingRatePicker.toggle()
        } label: {
            Text(player.rate.shortLabel)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 64, minHeight: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.playbackRateButton")
        .accessibilityLabel(L10n.string("player.playbackSpeed", player.rate.shortLabel))
        .popover(isPresented: $showingRatePicker, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            PlaybackRateFloatingPicker(player: player)
                .frame(minWidth: 340)
                .padding(.vertical, 8)
                .presentationCompactAdaptationIfAvailable()
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

/// Apple-style floating speed control. The horizontal scroll view exposes
/// the first six rates from the reference image and lets the user swipe to
/// reveal additional rates.
struct PlaybackRateFloatingPicker: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 8) {
            Text(L10n.string("player.speed"))
                .font(.headline)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(PlaybackRate.allCases) { rate in
                            rateCell(rate)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 76)
                .onAppear { proxy.scrollTo(player.rate.id, anchor: .center) }
                .onChange(of: player.rate) { rate in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(rate.id, anchor: .center)
                    }
                }
            }
            Text("Deslize para ver mais velocidades")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("player.playbackRateFloatingPicker")
    }

    private func rateCell(_ rate: PlaybackRate) -> some View {
        let selected = player.rate == rate
        return Button {
            player.setRate(rate)
        } label: {
            Text(rate.shortLabel)
                .font(.body.monospacedDigit())
                .frame(width: 64, height: 64)
                .background(Circle().fill(selected ? Color.primary.opacity(0.78) : Color.secondary.opacity(0.22)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .id(rate.id)
        .accessibilityLabel(selected ? "\(rate.shortLabel), selected" : rate.shortLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Native system-volume control. `MPVolumeView` is the Apple-supported
/// control for changing the device/output volume; `outputVolume` itself is
/// read-only and must not be mirrored into a second SwiftUI slider.
struct SystemVolumeSlider: View {
    var body: some View {
        #if os(iOS)
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .frame(width: 24, height: 24)
                .scaledToFit()
            SystemVolumeSliderRepresentable()
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 24, height: 24)
                .scaledToFit()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .accessibilityLabel(L10n.string("player.systemVolume"))
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct SystemVolumeSliderRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

extension View {
    @ViewBuilder
    func presentationCompactAdaptationIfAvailable() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Player") {
    let player = AudioPlayer()
    return PlayerView(
        snapshot: JobSnapshot.previewSample,
        backendBaseURL: URL(string: "http://localhost:8000")
    )
    .environmentObject(player)
    .environmentObject(player.playbackClock)
    .environmentObject(ReaderCoordinator())
}
#endif

