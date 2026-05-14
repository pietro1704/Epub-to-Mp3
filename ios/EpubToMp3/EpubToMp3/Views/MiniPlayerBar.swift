import SwiftUI
import AVFoundation
import MediaPlayer

/// Persistent mini-player bar matching the Apple Podcasts / Apple Books HIG
/// pattern. Shown at the bottom of every surface that is NOT the Now Playing
/// full-screen view. Hidden when nothing is playing (`currentBookID == nil`).
///
/// Layout (64 pt height):
///   [cover 44×44] [title / chapter]  [play/pause] [skip +15s]
///   ─── 2pt progress bar (accentColor) across the top ──────────
///
/// Tap anywhere → `onTap()` → caller navigates to Now Playing.
///
/// HIG compliance:
/// - `.thinMaterial` background (same as Apple Books mini-player).
/// - All interactive targets ≥44×44 pt.
/// - Combined accessibility label + hint on the container.
/// - Dynamic Type via `.subheadline` / `.caption2`.
/// - `@Environment(\.accessibilityReduceMotion)` respected on appear transition.
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore

    /// Called when the user taps the bar — the hosting view should navigate
    /// to the Now Playing full-screen destination.
    var onTap: () -> Void

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)
    private var currentChapterIndex: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Derived state

    private var currentBook: BookEntity? {
        guard let id = currentBookID, !id.isEmpty else { return nil }
        return library.books.first { $0.id == id }
    }

    private var progress: Double {
        guard player.durationSeconds > 0 else { return 0 }
        return min(1, max(0, player.positionSeconds / player.durationSeconds))
    }

    private var chapterLabel: String {
        let idx = player.snapshot != nil ? player.currentChapterIndex : currentChapterIndex
        return "Chapter \(idx + 1)"
    }

    // MARK: Body

    var body: some View {
        if let book = currentBook {
            VStack(spacing: 0) {
                // 2pt progress bar at top.
                // During conversion: shows TTS progress (orange tint).
                // During playback: shows chapter playback position.
                GeometryReader { geo in
                    let barProgress: Double = {
                        if player.isConverting, let cp = player.conversionProgress {
                            return cp
                        }
                        return progress
                    }()
                    let barColor: Color = player.isConverting ? .orange : .accentColor
                    Rectangle()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * barProgress), height: 2)
                        .animation(.linear(duration: 0.3), value: barProgress)
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    coverView(for: book)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.resolvedTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(chapterLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Transport: spinner while converting & no audio yet;
                    // play/pause once the first chapter is ready.
                    if player.isConverting && !player.firstChapterReady {
                        ProgressView()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Generating audio")
                            .accessibilityIdentifier("miniPlayer.loadingSpinner")
                    } else {
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        .accessibilityIdentifier("miniPlayer.playPause")
                    }

                    Button {
                        player.skipForward(seconds: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isConverting && !player.firstChapterReady)
                    .accessibilityLabel("Skip forward 15 seconds")
                }
                // 12pt internal spacing on top of any safe-area lateral
                // inset so the cover and transport controls never sit
                // under the notch / Dynamic Island in landscape.
                .compatHorizontalSafeAreaPadding(12)
                .frame(height: 62)
            }
            .frame(height: 64)
            .background(.thinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing: \(book.resolvedTitle), \(chapterLabel). Tap to expand.")
            .accessibilityHint("Swipe up or tap to open full player.")
            .accessibilityIdentifier("miniPlayer.bar")
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
        }
    }

    // MARK: Cover

    @ViewBuilder
    private func coverView(for book: BookEntity) -> some View {
        if let data = book.coverPNG, let img = platformImage(from: data) {
            img.resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "book.closed")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tint)
            }
        }
    }

    private func platformImage(from data: Data) -> Image? {
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
    }
}

#if DEBUG
private struct MiniPlayerPreviewPlaying: View {
    private let lib = LibraryStore.previewPopulated
    private let player = AudioPlayer()
    init() {
        if let first = lib.books.first {
            UserDefaults.standard.set(first.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        }
    }
    var body: some View {
        VStack {
            Spacer()
            MiniPlayerBar(onTap: {})
                .environmentObject(player)
                .environmentObject(lib)
        }
        .background(Color.secondary.opacity(0.1))
    }
}

private struct MiniPlayerPreviewHidden: View {
    private let lib = LibraryStore.previewPopulated
    private let player = AudioPlayer()
    init() {
        UserDefaults.standard.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
    }
    var body: some View {
        VStack {
            Spacer()
            MiniPlayerBar(onTap: {})
                .environmentObject(player)
                .environmentObject(lib)
            Text("(no bar above — nothing playing)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
        .background(Color.secondary.opacity(0.1))
    }
}

#Preview("MiniPlayerBar — playing") { MiniPlayerPreviewPlaying() }
#Preview("MiniPlayerBar — hidden")  { MiniPlayerPreviewHidden() }
#endif
