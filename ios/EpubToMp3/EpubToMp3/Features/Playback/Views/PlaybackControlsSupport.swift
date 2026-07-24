import SwiftUI
#if os(iOS)
import MediaPlayer
#endif

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
