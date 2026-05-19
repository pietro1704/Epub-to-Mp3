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

    @AppStorage(AudioPlayer.readerCurrentChapterIndexDefaultsKey)
    private var readerChapterIndex: Int = 0

    @State private var pendingAnchor: PlayDivergenceAnchor?

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
        // Prefer the displayTitle from the live snapshot (matches FullPlayerSheet behaviour).
        if let chapters = player.snapshot?.playableChapters, idx < chapters.count {
            return chapters[idx].displayTitle
        }
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
                    // The cover + title area is the *only* surface that
                    // expands the player on tap. Buttons below have their
                    // own gesture targets and stay independent.
                    Button {
                        onTap()
                    } label: {
                        HStack(spacing: 12) {
                            coverView(for: book)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.resolvedTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(chapterLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.string("miniPlayer.expandHint"))

                    // Inline transport: play/pause + next chapter. Tap on
                    // the *bar* (anywhere outside these buttons) expands
                    // to the full player — SwiftUI's gesture dispatch
                    // gives the buttons priority over the bar's
                    // `onTapGesture`, so play/pause never accidentally
                    // expands the sheet.
                    ZStack {
                        ProgressView()
                            .opacity(player.isConverting && !player.firstChapterReady ? 1 : 0)
                            .accessibilityLabel(L10n.string("player.generatingAudio"))
                            .accessibilityIdentifier("miniPlayer.loadingSpinner")
                        Button {
                            handlePlayTap()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(player.isConverting && !player.firstChapterReady ? 0 : 1)
                        .accessibilityLabel(player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play"))
                        .accessibilityIdentifier("miniPlayer.playPause")
                    }
                    .frame(width: 44, height: 44)

                    Button {
                        player.nextChapter()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 18))
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isConverting && !player.firstChapterReady)
                    .accessibilityLabel(L10n.string("player.nextChapter"))

                    // "..." popover — speed + sleep, the spec's "floater
                    // pra velocidade e sleep".
                    Menu {
                        Menu {
                            ForEach(PlaybackRate.allCases) { rate in
                                Button {
                                    player.setRate(rate)
                                } label: {
                                    if player.rate == rate {
                                        Label(rate.shortLabel, systemImage: "checkmark")
                                    } else {
                                        Text(rate.shortLabel)
                                    }
                                }
                            }
                        } label: {
                            Label(
                                L10n.string("player.playbackSpeed", player.rate.shortLabel),
                                systemImage: "speedometer"
                            )
                        }
                        Menu {
                            ForEach([0, 5, 15, 30, 45, 60], id: \.self) { minutes in
                                Button {
                                    if minutes == 0 {
                                        player.setSleepTimer(seconds: 0)
                                    } else {
                                        player.startSleepTimer(minutes: minutes)
                                    }
                                } label: {
                                    if minutes == 0 {
                                        Label(L10n.string("player.sleepTimerOption.off"), systemImage: "xmark")
                                    } else {
                                        Text(L10n.string("player.sleepTimerOption.\(minutes)"))
                                    }
                                }
                            }
                        } label: {
                            Label(L10n.string("player.sleepTimer"), systemImage: "moon.zzz")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18))
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.string("player.more"))
                    .accessibilityIdentifier("miniPlayer.more")
                }
                // 12pt internal spacing on top of any safe-area lateral
                // inset so the cover and transport controls never sit
                // under the notch / Dynamic Island in landscape.
                .compatHorizontalSafeAreaPadding(12)
                .frame(minHeight: 62)
            }
            .frame(minHeight: 64)
            .background(.thinMaterial)
            // Pull-up: an upward drag of ≥20pt anywhere on the bar
            // expands. The dedicated cover/title button (above) handles
            // tap-to-expand without intercepting taps on the buttons
            // (play/pause, next, "..."), which was the previous bug.
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.height < -20
                            || value.predictedEndTranslation.height < -60 {
                            onTap()
                        }
                    }
            )
            // Keep child accessibility behaviour intact — `.combine` was
            // making SwiftUI route every tap inside the bar to the
            // bar-level accessibility element (which triggered the
            // `expand` action), so play/pause / next / "..." were all
            // expanding the sheet. `.contain` keeps each button focusable
            // separately.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("miniPlayer.bar")
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
            .playDivergenceDialog(player: player, anchor: $pendingAnchor)
        }
    }

    // MARK: Play / divergence routing
    //
    // Delegates the decision logic and the start-options dialog to
    // `AudioPlayer` + the `.playDivergenceDialog` view modifier so
    // every play-button surface in the app shares one implementation.

    private func handlePlayTap() {
        switch player.playTapDecision(readerChapterIndex: readerChapterIndex) {
        case .pause, .resume:
            player.togglePlayPause()
        case .offerStartChoice:
            // Snapshot the reader's anchor RIGHT NOW so the dialog
            // animation (and any further user swipes during it)
            // can't drift the captured position.
            pendingAnchor = .capture(readerChapterIndex: readerChapterIndex)
        }
    }

    // MARK: Cover

    @ViewBuilder
    private func coverView(for book: BookEntity) -> some View {
        if let data = book.coverPNG, let img = platformImage(from: data) {
            img.resizable().aspectRatio(contentMode: .fit)
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
