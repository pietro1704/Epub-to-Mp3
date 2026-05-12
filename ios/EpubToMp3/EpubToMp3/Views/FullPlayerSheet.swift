#if canImport(AVFoundation) && canImport(MediaPlayer)
import SwiftUI

/// Full-screen audiobook player sheet. Mirrors the Apple Music /
/// Apple Books HIG full-player pattern:
///
///   ┌─────────────────────┐
///   │    ⎯  drag handle   │  (provided by the system sheet)
///   │                     │
///   │   [cover art 300]   │
///   │   Book Title  XL    │
///   │   Author / chapter  │
///   │                     │
///   │  ─── scrubber ────  │
///   │  0:00          4:32 │
///   │                     │
///   │  |◀  ⏮  ▶  ⏭  ▶|  │  (skip-15 / play-pause / skip+15)
///   │                     │
///   │  speed  sleep  AirPlay │
///   └─────────────────────┘
///
/// Presentation: `.sheet(isPresented:)` with `.presentationDetents([.large])`.
/// iOS 16+: native detent. iOS 15 fallback: the sheet fills the screen
/// by default (`.large` is the only detent that existed before iOS 16).
/// Swipe-down dismisses (sheet default behaviour).
struct FullPlayerSheet: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryStore

    @AppStorage(AudioPlayer.currentBookIDDefaultsKey)
    private var currentBookID: String?

    @AppStorage(AudioPlayer.currentChapterIndexDefaultsKey)
    private var currentChapterIndex: Int = 0

    @Environment(\.dismiss) private var dismiss

    // MARK: Derived state

    private var currentBook: BookEntity? {
        guard let id = currentBookID, !id.isEmpty else { return nil }
        return library.books.first { $0.id == id }
    }

    private var chapterLabel: String {
        let idx = player.snapshot != nil ? player.currentChapterIndex : currentChapterIndex
        guard let chapters = player.snapshot?.playableChapters,
              idx < chapters.count else {
            return "Chapter \(idx + 1)"
        }
        return chapters[idx].displayTitle
    }

    private var progress: Double {
        guard player.durationSeconds > 0 else { return 0 }
        return min(1, max(0, player.positionSeconds / player.durationSeconds))
    }

    // MARK: Body

    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            modernBody
        } else {
            legacyBody
        }
    }

    @available(iOS 16, macOS 13, *)
    private var modernBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Top breathing room. The NavigationStack toolbar
                    // already covers the notch, so we only need a
                    // small visual gap below it — but bump from 8pt to
                    // 16pt so the cover hero doesn't kiss the close
                    // chevron on devices with a Dynamic Island where
                    // the inline title sits lower.
                    Spacer(minLength: 16)
                    coverHero
                    titleBlock
                    scrubberBlock
                    transportRow
                    secondaryRow
                    // Bottom breathing room. The sheet draws over the
                    // home indicator, so the system bottom safe-area
                    // inset already lifts content above it; this
                    // 32pt is in addition to that — gives the
                    // secondaryRow buttons a comfortable gap.
                    Spacer(minLength: 32)
                }
                // 32pt margin sits on top of the system horizontal safe
                // area so cover art / scrubber / transport buttons stay
                // clear of the notch when the sheet is presented over a
                // landscape iPhone.
                .compatHorizontalSafeAreaPadding(32)
            }
            .scrollBounceBehaviorIfAvailable()
            .background(backgroundLayer.ignoresSafeArea())
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close player")
                }
            }
        }
        // iOS 16+: lock the sheet to large detent.
        // iOS 15: .sheet is implicitly full-screen — no-op.
        .sheetLargeDetentIfAvailable()
    }

    /// iOS 15 fallback: plain scroll layout without NavigationStack.
    /// Because there is no NavigationStack here, nothing covers the
    /// notch — so the cover hero would otherwise rise into the
    /// Dynamic Island in portrait. Inject explicit top + bottom
    /// breathing room above what the system safe-area inset already
    /// provides on the ScrollView's content. `.ignoresSafeArea()` is
    /// on the background only (full-bleed gradient is the HIG look),
    /// so the ScrollView content stays inside the safe area.
    private var legacyBody: some View {
        ScrollView {
            VStack(spacing: 28) {
                // 24pt top margin above the system safe-area inset.
                // The system inset on iPhone X-later is ~44-59pt
                // (status bar + Dynamic Island). 24pt extra means the
                // cover hero starts well clear of the notch in
                // portrait — no crop on the curved corners either.
                Spacer(minLength: 24)
                coverHero
                titleBlock
                scrubberBlock
                transportRow
                secondaryRow
                Spacer(minLength: 24)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                // Lift the Close button comfortably above the home
                // indicator. The system safe-area bottom inset
                // already accounts for the indicator itself (34pt);
                // this 24pt is the additional visual breathing room.
                Spacer(minLength: 24)
            }
            // 32pt margin sits on top of the system horizontal safe
            // area so cover art / scrubber / transport buttons stay
            // clear of the notch when the sheet is presented over a
            // landscape iPhone.
            .compatHorizontalSafeAreaPadding(32)
        }
        .scrollBounceBehaviorIfAvailable()
        .background(backgroundLayer.ignoresSafeArea())
    }

    // MARK: - Cover hero

    private var coverHero: some View {
        Group {
            if let book = currentBook,
               let data = book.coverPNG,
               let img = platformImage(from: data) {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "headphones")
                        .font(.system(size: 80, weight: .ultraLight))
                        .foregroundStyle(.tint)
                }
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            }
        }
        // Subtle scale-up on appear — matches Apple Music entry animation.
        .scaleEffect(1.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: currentBookID)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(spacing: 6) {
            if let book = currentBook {
                Text(book.resolvedTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(chapterLabel)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Scrubber

    private var scrubberBlock: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.positionSeconds },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.durationSeconds, 1)
            )
            .tint(.primary)

            HStack {
                Text(formatTime(player.positionSeconds))
                Spacer()
                Text(formatTime(player.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer()

            // Skip back 15 s
            Button {
                player.skipBackward(seconds: 15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back 15 seconds")

            Spacer()

            // Play / Pause — 64pt circle (Apple Music standard)
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.primary)
                            .frame(width: 72, height: 72)
                    } else {
                        Image(
                            systemName: player.isPlaying
                                ? "pause.circle.fill"
                                : "play.circle.fill"
                        )
                        .font(.system(size: 72))
                        .frame(width: 72, height: 72)
                    }
                }
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            // Skip forward 15 s
            Button {
                player.skipForward(seconds: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 15 seconds")

            Spacer()
        }
    }

    // MARK: - Secondary row (rate + sleep + AirPlay)

    private var secondaryRow: some View {
        HStack(spacing: 24) {
            // Rate picker — compact menu button matching Apple Music's
            // "1x" pill in the lower-left.
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
                Text(player.rate.shortLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 56, minHeight: 44)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Playback speed: \(player.rate.shortLabel)")

            Spacer()

            // Sleep timer — shows remaining if active
            SleepTimerButton()

            Spacer()

            // AirPlay route picker (iOS only — macOS uses menu-bar route picker)
            #if os(iOS)
            AirPlayPickerView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            #endif
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        // Use `.thinMaterial` as the backdrop so artwork colours
        // show through on iOS; macOS uses its own window chrome.
        Color.clear
            .background(.thinMaterial)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func platformImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #endif
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

// MARK: - Sleep timer button

/// Inline sleep-timer affordance: tap to cycle through presets, shows
/// remaining time when active (Apple Podcasts pattern).
private struct SleepTimerButton: View {
    @EnvironmentObject private var player: AudioPlayer

    private let presets: [TimeInterval] = [0, 15*60, 30*60, 45*60, 60*60]

    var body: some View {
        Button {
            cycleTimer()
        } label: {
            Label {
                if player.sleepTimerRemaining > 0 {
                    Text(formatRemaining(player.sleepTimerRemaining))
                        .monospacedDigit()
                } else {
                    Text("Sleep")
                }
            } icon: {
                Image(systemName: "moon.zzz")
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 70, minHeight: 44)
            .padding(.horizontal, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            player.sleepTimerRemaining > 0
                ? "Sleep timer: \(formatRemaining(player.sleepTimerRemaining)) remaining. Tap to cancel."
                : "Sleep timer: off. Tap to set."
        )
    }

    private func cycleTimer() {
        let current = player.sleepTimerRemaining
        let next = presets.first { $0 > current } ?? 0
        player.setSleepTimer(seconds: next)
    }

    private func formatRemaining(_ secs: TimeInterval) -> String {
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - View modifier helpers (availability-gated API)

private extension View {
    /// Apply `.presentationDetents([.large])` on iOS 16+; no-op on iOS 15.
    @ViewBuilder
    func sheetLargeDetentIfAvailable() -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.presentationDetents([.large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    /// Bounce behaviour polyfill — only exists on iOS 16.4+.
    @ViewBuilder
    func scrollBounceBehaviorIfAvailable() -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Full Player Sheet") {
    let lib = LibraryStore.previewPopulated
    let player = AudioPlayer()
    if let first = lib.books.first {
        UserDefaults.standard.set(first.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
    }
    return FullPlayerSheet()
        .environmentObject(player)
        .environmentObject(lib)
}
#endif
#endif
